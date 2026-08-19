use crate::process::hide_console_window;
use base64::Engine;
use quick_xml::events::Event;
use quick_xml::Reader;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use thiserror::Error;
use zip::ZipArchive;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PreviewKind {
    Text,
    Markdown,
    Code,
    Html,
    Image,
    Pdf,
    Document,
    Presentation,
    Spreadsheet,
    Unsupported,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PreviewPayload {
    pub name: String,
    pub path: String,
    pub kind: PreviewKind,
    pub mime_type: String,
    pub content: String,
    pub sections: Vec<String>,
    pub size_bytes: u64,
    #[serde(default)]
    pub revision: String,
    #[serde(default)]
    pub rendered_content: Option<String>,
    #[serde(default)]
    pub rendered_mime_type: Option<String>,
    #[serde(default)]
    pub faithful: bool,
}

#[derive(Debug, Error)]
pub enum PreviewError {
    #[error("file does not exist: {0}")]
    Missing(String),
    #[error("could not read preview file: {0}")]
    Read(#[from] std::io::Error),
    #[error("could not read Office package: {0}")]
    Zip(#[from] zip::result::ZipError),
}

pub(crate) fn content_revision(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub(crate) fn file_revision(path: impl AsRef<Path>) -> Result<String, PreviewError> {
    Ok(content_revision(&fs::read(path)?))
}

pub(crate) fn semantic_file_revision(path: impl AsRef<Path>) -> Result<String, PreviewError> {
    let path = path.as_ref();
    let preview = preview_file(path)?;
    let bytes = fs::read(path)?;
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let mut hasher = Sha256::new();
    hasher.update(
        serde_json::to_string(&preview.kind)
            .unwrap_or_default()
            .as_bytes(),
    );
    hasher.update(preview.mime_type.as_bytes());
    hasher.update(if preview.faithful {
        b"faithful".as_slice()
    } else {
        b"textual".as_slice()
    });

    match preview.kind {
        PreviewKind::Image => hasher.update(&bytes),
        PreviewKind::Unsupported => hasher.update(&bytes),
        PreviewKind::Pdf => {
            hasher.update(format!("pages:{}", preview.sections.len()).as_bytes());
            for section in &preview.sections {
                hasher.update(b"\0page\0");
                hasher.update(normalize_semantic_text(section).as_bytes());
            }
            // Extracted text alone misses layout, color, vector, image, font, and annotation
            // changes. Canonicalize the page-facing PDF object graph instead of hashing the raw
            // container, whose Info dictionary, trailer ID, xref offsets, and timestamps are
            // volatile. A malformed/unsupported PDF falls back to exact bytes rather than losing
            // a real revision.
            if let Some(visual_revision) = pdf_visual_revision(&bytes) {
                hasher.update(b"\0pdf-visual\0");
                hasher.update(visual_revision.as_bytes());
            } else {
                hasher.update(b"\0pdf-fallback\0");
                hasher.update(&bytes);
            }
        }
        _ => {
            hasher.update(normalize_semantic_text(&preview.content).as_bytes());
            for section in &preview.sections {
                hasher.update(b"\0section\0");
                hasher.update(normalize_semantic_text(section).as_bytes());
            }
        }
    }

    // Hash decompressed OOXML parts in name order. ZIP timestamps, compression choices, entry
    // ordering, and volatile core document timestamps cannot manufacture semantic progress;
    // slide themes, layouts, styles, relationships, media, and audience content still can.
    let office_prefix = match extension.as_str() {
        "docx" => Some("word/"),
        "pptx" => Some("ppt/"),
        "xlsx" => Some("xl/"),
        _ => None,
    };
    if let Some(prefix) = office_prefix {
        let mut archive = ZipArchive::new(Cursor::new(bytes))?;
        let mut parts = Vec::new();
        for index in 0..archive.len() {
            let mut entry = archive.by_index(index)?;
            let name = entry.name().replace('\\', "/");
            if !name.starts_with(prefix) || entry.is_dir() {
                continue;
            }
            let mut part = Vec::new();
            entry.read_to_end(&mut part)?;
            if name.ends_with(".xml") || name.ends_with(".rels") {
                part = normalize_semantic_text(&String::from_utf8_lossy(&part)).into_bytes();
            }
            parts.push((name, part));
        }
        parts.sort_by(|left, right| left.0.cmp(&right.0));
        for (name, part) in parts {
            hasher.update(b"\0part\0");
            hasher.update(name.as_bytes());
            hasher.update(b"\0");
            hasher.update(part);
        }
    } else if let (Some(rendered), Some(mime_type)) =
        (&preview.rendered_content, &preview.rendered_mime_type)
    {
        // PDF exporters commonly inject timestamps and document ids. Office sources are covered
        // by their canonical package parts above; other faithful rendered payloads can be hashed
        // directly when their format is not PDF.
        if mime_type != "application/pdf" {
            if let Some((_, payload)) = rendered.split_once(',') {
                if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(payload) {
                    hasher.update(decoded);
                }
            }
        }
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn normalize_semantic_text(value: &str) -> String {
    value
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .lines()
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

fn pdf_visual_revision(bytes: &[u8]) -> Option<String> {
    use pdf_extract::Document;

    let document = Document::load_mem(bytes).ok()?;
    let pages = document.get_pages();
    if pages.is_empty() {
        return None;
    }

    let mut hasher = Sha256::new();
    hasher.update(b"lingshu-pdf-visual-v1");
    hasher.update((pages.len() as u64).to_be_bytes());
    let mut active_references = HashSet::new();

    if let Ok(catalog) = document.catalog() {
        for key in [b"OutputIntents".as_slice(), b"OCProperties".as_slice()] {
            if let Ok(value) = catalog.get(key) {
                hash_tagged_bytes(&mut hasher, b"catalog-key", key);
                hash_pdf_object(
                    &document,
                    value,
                    &mut hasher,
                    &mut active_references,
                    0,
                    false,
                );
            }
        }
    }

    for (page_number, page_id) in pages {
        hasher.update(b"\0page\0");
        hasher.update(page_number.to_be_bytes());
        for key in [
            b"MediaBox".as_slice(),
            b"CropBox".as_slice(),
            b"BleedBox".as_slice(),
            b"TrimBox".as_slice(),
            b"ArtBox".as_slice(),
            b"Rotate".as_slice(),
            b"UserUnit".as_slice(),
            b"Resources".as_slice(),
            b"Contents".as_slice(),
            b"Annots".as_slice(),
            b"Group".as_slice(),
        ] {
            if let Some(value) = inherited_pdf_page_value(&document, page_id, key) {
                hash_tagged_bytes(&mut hasher, b"page-key", key);
                hash_pdf_object(
                    &document,
                    value,
                    &mut hasher,
                    &mut active_references,
                    0,
                    key == b"Contents",
                );
            }
        }
    }

    Some(format!("{:x}", hasher.finalize()))
}

fn inherited_pdf_page_value<'a>(
    document: &'a pdf_extract::Document,
    page_id: pdf_extract::ObjectId,
    key: &[u8],
) -> Option<&'a pdf_extract::Object> {
    let mut current_id = page_id;
    let mut visited = HashSet::new();
    loop {
        if !visited.insert(current_id) {
            return None;
        }
        let dictionary = document.get_dictionary(current_id).ok()?;
        if let Ok(value) = dictionary.get(key) {
            return Some(value);
        }
        current_id = dictionary.get(b"Parent").ok()?.as_reference().ok()?;
    }
}

fn hash_pdf_object(
    document: &pdf_extract::Document,
    object: &pdf_extract::Object,
    hasher: &mut Sha256,
    active_references: &mut HashSet<pdf_extract::ObjectId>,
    depth: usize,
    content_stream: bool,
) {
    use pdf_extract::Object;

    if depth > 64 {
        hasher.update(b"depth-limit");
        return;
    }
    match object {
        Object::Null => hasher.update(b"null"),
        Object::Boolean(value) => {
            hasher.update(b"bool");
            hasher.update([u8::from(*value)]);
        }
        Object::Integer(value) => {
            hasher.update(b"integer");
            hasher.update(value.to_be_bytes());
        }
        Object::Real(value) => {
            hasher.update(b"real");
            let normalized = if *value == 0.0 { 0.0 } else { *value };
            hasher.update(normalized.to_bits().to_be_bytes());
        }
        Object::Name(value) => hash_tagged_bytes(hasher, b"name", value),
        Object::String(value, _) => hash_tagged_bytes(hasher, b"string", value),
        Object::Array(values) => {
            hasher.update(b"array");
            hasher.update((values.len() as u64).to_be_bytes());
            for value in values {
                hash_pdf_object(
                    document,
                    value,
                    hasher,
                    active_references,
                    depth + 1,
                    content_stream,
                );
            }
        }
        Object::Dictionary(dictionary) => hash_pdf_dictionary(
            document,
            dictionary,
            hasher,
            active_references,
            depth + 1,
            false,
        ),
        Object::Stream(stream) => {
            let (content, decompressed) = match stream.decompressed_content() {
                Ok(content) => (content, true),
                Err(_) => (stream.content.clone(), false),
            };
            hash_pdf_dictionary(
                document,
                &stream.dict,
                hasher,
                active_references,
                depth + 1,
                decompressed,
            );
            let is_form = stream
                .dict
                .get(b"Subtype")
                .ok()
                .and_then(|value| value.as_name().ok())
                == Some(b"Form".as_slice());
            let canonical_content = if content_stream || is_form {
                pdf_extract::content::Content::decode(&content)
                    .and_then(|content| content.encode())
                    .unwrap_or(content)
            } else {
                content
            };
            hash_tagged_bytes(hasher, b"stream-content", &canonical_content);
        }
        Object::Reference(object_id) => {
            if !active_references.insert(*object_id) {
                hasher.update(b"reference-cycle");
                return;
            }
            hasher.update(b"reference");
            if let Ok(value) = document.get_object(*object_id) {
                hash_pdf_object(
                    document,
                    value,
                    hasher,
                    active_references,
                    depth + 1,
                    content_stream,
                );
            } else {
                hasher.update(b"missing-reference");
            }
            active_references.remove(object_id);
        }
    }
}

fn hash_pdf_dictionary(
    document: &pdf_extract::Document,
    dictionary: &pdf_extract::Dictionary,
    hasher: &mut Sha256,
    active_references: &mut HashSet<pdf_extract::ObjectId>,
    depth: usize,
    decompressed_stream: bool,
) {
    let mut entries = dictionary
        .iter()
        .filter(|(key, _)| {
            !is_pdf_metadata_key(key)
                && key.as_slice() != b"Length"
                && (!decompressed_stream || !matches!(key.as_slice(), b"Filter" | b"DecodeParms"))
        })
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| left.0.cmp(right.0));
    hasher.update(b"dictionary");
    hasher.update((entries.len() as u64).to_be_bytes());
    for (key, value) in entries {
        hash_tagged_bytes(hasher, b"dictionary-key", key);
        hash_pdf_object(document, value, hasher, active_references, depth + 1, false);
    }
}

fn is_pdf_metadata_key(key: &[u8]) -> bool {
    matches!(
        key,
        b"Metadata"
            | b"PieceInfo"
            | b"LastModified"
            | b"StructParent"
            | b"StructParents"
            | b"CreationDate"
            | b"ModDate"
            | b"Producer"
            | b"Creator"
            | b"Author"
            | b"Title"
            | b"Subject"
            | b"Keywords"
            | b"Trapped"
            | b"Info"
            | b"ID"
    )
}

fn hash_tagged_bytes(hasher: &mut Sha256, tag: &[u8], value: &[u8]) {
    hasher.update(tag);
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value);
}

pub fn preview_file(path: impl AsRef<Path>) -> Result<PreviewPayload, PreviewError> {
    let path = path.as_ref();
    if !path.is_file() {
        return Err(PreviewError::Missing(path.display().to_string()));
    }
    let metadata = fs::metadata(path)?;
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("file")
        .to_string();
    let ext = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let bytes = fs::read(path)?;
    let revision = content_revision(&bytes);
    let mut payload = PreviewPayload {
        name,
        path: path.display().to_string(),
        kind: PreviewKind::Unsupported,
        mime_type: "application/octet-stream".into(),
        content: String::new(),
        sections: Vec::new(),
        size_bytes: metadata.len(),
        revision: revision.clone(),
        rendered_content: None,
        rendered_mime_type: None,
        faithful: false,
    };
    match ext.as_str() {
        "md" | "markdown" => {
            payload.kind = PreviewKind::Markdown;
            payload.mime_type = "text/markdown".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
            payload.faithful = true;
        }
        "txt" | "log" | "csv" | "tsv" => {
            payload.kind = PreviewKind::Text;
            payload.mime_type = "text/plain".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
            payload.faithful = true;
        }
        "json" | "yaml" | "yml" | "toml" | "xml" | "rs" | "swift" | "js" | "ts" | "tsx" | "jsx"
        | "py" | "sh" | "ps1" | "css" => {
            payload.kind = PreviewKind::Code;
            payload.mime_type = "text/plain".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
            payload.faithful = true;
        }
        "html" | "htm" => {
            payload.kind = PreviewKind::Html;
            payload.mime_type = "text/html".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
            payload.faithful = true;
        }
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "svg" => {
            payload.kind = PreviewKind::Image;
            payload.mime_type = image_mime(&ext).into();
            payload.content = format!(
                "data:{};base64,{}",
                payload.mime_type,
                base64::engine::general_purpose::STANDARD.encode(bytes)
            );
            payload.faithful = true;
        }
        "pdf" => {
            payload.kind = PreviewKind::Pdf;
            payload.mime_type = "application/pdf".into();
            // Preserve the original bytes for preview while exposing embedded text to the
            // cross-platform agent kernel. This pure-Rust path needs no host PDF plugin.
            payload.sections = pdf_extract::extract_text_from_mem_by_pages(&bytes)
                .unwrap_or_default()
                .into_iter()
                .map(|page| page.trim().to_string())
                .filter(|page| !page.is_empty())
                .collect();
            payload.content = format!(
                "data:application/pdf;base64,{}",
                base64::engine::general_purpose::STANDARD.encode(bytes)
            );
            payload.faithful = true;
        }
        "docx" => {
            payload.kind = PreviewKind::Document;
            payload.mime_type =
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document".into();
            let text = office_part_text(&bytes, "word/document.xml")?;
            payload.sections = text
                .lines()
                .filter(|line| !line.trim().is_empty())
                .map(str::to_string)
                .collect();
            payload.content = text;
        }
        "pptx" => {
            payload.kind = PreviewKind::Presentation;
            payload.mime_type =
                "application/vnd.openxmlformats-officedocument.presentationml.presentation".into();
            payload.sections = presentation_slides(&bytes)?;
            payload.content = payload.sections.join("\n\n");
            if let Some(rendered) = render_presentation_pdf(path, &revision) {
                payload.rendered_content = Some(format!(
                    "data:application/pdf;base64,{}",
                    base64::engine::general_purpose::STANDARD.encode(rendered)
                ));
                payload.rendered_mime_type = Some("application/pdf".into());
                payload.faithful = true;
            }
        }
        "xlsx" => {
            payload.kind = PreviewKind::Spreadsheet;
            payload.mime_type =
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".into();
            payload.sections = spreadsheet_sheets(&bytes)?;
            payload.content = payload.sections.join("\n\n");
        }
        _ => {}
    }
    Ok(payload)
}

fn render_presentation_pdf(path: &Path, revision: &str) -> Option<Vec<u8>> {
    let cache_dir = std::env::temp_dir().join("lingshu-preview").join(revision);
    fs::create_dir_all(&cache_dir).ok()?;
    let cached_pdf = cache_dir.join("presentation.pdf");
    if cached_pdf.is_file() {
        return fs::read(cached_pdf).ok();
    }

    #[cfg(target_os = "windows")]
    if render_with_powerpoint(path, &cached_pdf) && cached_pdf.is_file() {
        return fs::read(cached_pdf).ok();
    }

    let converted = render_with_libreoffice(path, &cache_dir)?;
    if converted != cached_pdf {
        fs::rename(&converted, &cached_pdf)
            .or_else(|_| fs::copy(&converted, &cached_pdf).map(|_| ()))
            .ok()?;
    }
    fs::read(cached_pdf).ok()
}

#[cfg(target_os = "windows")]
fn render_with_powerpoint(source: &Path, destination: &Path) -> bool {
    let source = powershell_literal(source);
    let destination = powershell_literal(destination);
    let script = format!(
        "$ErrorActionPreference='Stop'; $app=New-Object -ComObject PowerPoint.Application; \
         $presentation=$app.Presentations.Open('{source}',$true,$true,$false); \
         $presentation.SaveAs('{destination}',32); $presentation.Close(); $app.Quit();"
    );
    ["powershell.exe", "pwsh.exe"].into_iter().any(|program| {
        let mut command = Command::new(program);
        command.args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &script,
        ]);
        command_succeeds(command, Duration::from_secs(90))
    })
}

#[cfg(target_os = "windows")]
fn powershell_literal(path: &Path) -> String {
    path.display().to_string().replace('\'', "''")
}

fn render_with_libreoffice(source: &Path, output_dir: &Path) -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    let candidates = [
        PathBuf::from("soffice.exe"),
        PathBuf::from(r"C:\Program Files\LibreOffice\program\soffice.exe"),
        PathBuf::from(r"C:\Program Files (x86)\LibreOffice\program\soffice.exe"),
    ];
    #[cfg(target_os = "macos")]
    let candidates = [
        PathBuf::from("/Applications/LibreOffice.app/Contents/MacOS/soffice"),
        PathBuf::from("/opt/homebrew/bin/soffice"),
        PathBuf::from("/usr/local/bin/soffice"),
        PathBuf::from("soffice"),
    ];
    #[cfg(all(not(target_os = "windows"), not(target_os = "macos")))]
    let candidates = [PathBuf::from("soffice"), PathBuf::from("libreoffice")];

    let output_name = source
        .file_stem()
        .map(|stem| PathBuf::from(stem).with_extension("pdf"))?;
    let output_path = output_dir.join(output_name);
    for candidate in candidates {
        let mut command = Command::new(candidate);
        command
            .arg("--headless")
            .arg("--convert-to")
            .arg("pdf")
            .arg("--outdir")
            .arg(output_dir)
            .arg(source);
        if command_succeeds(command, Duration::from_secs(90)) && output_path.is_file() {
            return Some(output_path);
        }
    }
    None
}

fn command_succeeds(mut command: Command, timeout: Duration) -> bool {
    command.stdout(Stdio::null()).stderr(Stdio::null());
    hide_console_window(&mut command);
    let Ok(mut child) = command.spawn() else {
        return false;
    };
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if started.elapsed() < timeout => thread::sleep(Duration::from_millis(100)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

fn image_mime(ext: &str) -> &'static str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        _ => "image/png",
    }
}

fn office_part_text(bytes: &[u8], part: &str) -> Result<String, PreviewError> {
    let mut archive = ZipArchive::new(Cursor::new(bytes))?;
    let mut xml = String::new();
    archive.by_name(part)?.read_to_string(&mut xml)?;
    Ok(xml_text(&xml))
}

fn presentation_slides(bytes: &[u8]) -> Result<Vec<String>, PreviewError> {
    let mut archive = ZipArchive::new(Cursor::new(bytes))?;
    let mut names: Vec<String> = (0..archive.len())
        .filter_map(|index| {
            archive
                .by_index(index)
                .ok()
                .map(|file| file.name().to_string())
        })
        .filter(|name| name.starts_with("ppt/slides/slide") && name.ends_with(".xml"))
        .collect();
    names.sort_by_key(|name| slide_number(name));
    let mut slides = Vec::new();
    for name in names {
        let mut xml = String::new();
        archive.by_name(&name)?.read_to_string(&mut xml)?;
        slides.push(xml_text(&xml));
    }
    Ok(slides)
}

fn slide_number(name: &str) -> u32 {
    name.rsplit("slide")
        .next()
        .and_then(|part| part.strip_suffix(".xml"))
        .and_then(|part| part.parse().ok())
        .unwrap_or(u32::MAX)
}

fn spreadsheet_sheets(bytes: &[u8]) -> Result<Vec<String>, PreviewError> {
    let mut archive = ZipArchive::new(Cursor::new(bytes))?;
    let names = zip_text_if_present(&mut archive, "xl/workbook.xml")
        .map(|xml| workbook_sheet_names(&xml))
        .unwrap_or_default();
    let shared_strings = zip_text_if_present(&mut archive, "xl/sharedStrings.xml")
        .map(|xml| shared_string_values(&xml))
        .unwrap_or_default();
    let mut parts: Vec<String> = (0..archive.len())
        .filter_map(|index| {
            archive
                .by_index(index)
                .ok()
                .map(|file| file.name().to_string())
        })
        .filter(|name| name.starts_with("xl/worksheets/sheet") && name.ends_with(".xml"))
        .collect();
    parts.sort_by_key(|name| worksheet_number(name));
    let mut sheets = Vec::new();
    for (index, part) in parts.iter().enumerate() {
        let mut xml = String::new();
        archive.by_name(part)?.read_to_string(&mut xml)?;
        let title = names
            .get(index)
            .cloned()
            .unwrap_or_else(|| format!("Sheet {}", index + 1));
        let rows = worksheet_rows(&xml, &shared_strings);
        sheets.push(if rows.is_empty() {
            title
        } else {
            format!("{title}\n{}", rows.join("\n"))
        });
    }
    Ok(sheets)
}

fn zip_text_if_present(archive: &mut ZipArchive<Cursor<&[u8]>>, part: &str) -> Option<String> {
    let mut file = archive.by_name(part).ok()?;
    let mut xml = String::new();
    file.read_to_string(&mut xml).ok()?;
    Some(xml)
}

fn workbook_sheet_names(xml: &str) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    let mut names = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(event)) | Ok(Event::Empty(event))
                if event.name().as_ref() == b"sheet" =>
            {
                if let Some(name) = xml_attribute(&event, b"name") {
                    names.push(name);
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
    }
    names
}

fn shared_string_values(xml: &str) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    let mut values = Vec::new();
    let mut current = String::new();
    let mut in_item = false;
    loop {
        match reader.read_event() {
            Ok(Event::Start(event)) if event.name().as_ref() == b"si" => {
                current.clear();
                in_item = true;
            }
            Ok(Event::Text(text)) if in_item => {
                current.push_str(&decoded_xml_text(&text));
            }
            Ok(Event::End(event)) if event.name().as_ref() == b"si" => {
                values.push(current.clone());
                in_item = false;
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
    }
    values
}

fn worksheet_rows(xml: &str, shared_strings: &[String]) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    let mut rows = Vec::new();
    let mut cells = Vec::<(usize, String)>::new();
    let mut cell_column = 0usize;
    let mut cell_type = String::new();
    let mut cell_value = String::new();
    let mut in_cell = false;
    let mut capture_value = false;
    loop {
        match reader.read_event() {
            Ok(Event::Start(event)) if event.name().as_ref() == b"c" => {
                in_cell = true;
                cell_type = xml_attribute(&event, b"t").unwrap_or_default();
                cell_column = xml_attribute(&event, b"r")
                    .as_deref()
                    .map(spreadsheet_column_index)
                    .unwrap_or(cells.len());
                cell_value.clear();
            }
            Ok(Event::Empty(event)) if event.name().as_ref() == b"c" => {
                let column = xml_attribute(&event, b"r")
                    .as_deref()
                    .map(spreadsheet_column_index)
                    .unwrap_or(cells.len());
                cells.push((column, String::new()));
            }
            Ok(Event::Start(event)) if in_cell && matches!(event.name().as_ref(), b"v" | b"t") => {
                capture_value = true;
            }
            Ok(Event::Text(text)) if capture_value => {
                cell_value.push_str(&decoded_xml_text(&text));
            }
            Ok(Event::End(event)) if matches!(event.name().as_ref(), b"v" | b"t") => {
                capture_value = false;
            }
            Ok(Event::End(event)) if event.name().as_ref() == b"c" => {
                let value = match cell_type.as_str() {
                    "s" => cell_value
                        .parse::<usize>()
                        .ok()
                        .and_then(|index| shared_strings.get(index))
                        .cloned()
                        .unwrap_or_default(),
                    "b" => match cell_value.as_str() {
                        "1" => "TRUE".into(),
                        "0" => "FALSE".into(),
                        _ => cell_value.clone(),
                    },
                    _ => cell_value.clone(),
                };
                cells.push((cell_column, value));
                in_cell = false;
                capture_value = false;
            }
            Ok(Event::End(event)) if event.name().as_ref() == b"row" => {
                if !cells.is_empty() {
                    let width = cells.iter().map(|(column, _)| *column).max().unwrap_or(0) + 1;
                    let mut values = vec![String::new(); width];
                    for (column, value) in cells.drain(..) {
                        values[column] = value;
                    }
                    rows.push(values.join("\t"));
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
    }
    rows
}

fn xml_attribute(event: &quick_xml::events::BytesStart<'_>, key: &[u8]) -> Option<String> {
    event
        .attributes()
        .flatten()
        .find(|attribute| attribute.key.as_ref() == key)
        .and_then(|attribute| attribute.unescape_value().ok())
        .map(|value| value.into_owned())
}

fn decoded_xml_text(text: &quick_xml::events::BytesText<'_>) -> String {
    text.decode()
        .ok()
        .and_then(|decoded| {
            quick_xml::escape::unescape(&decoded)
                .ok()
                .map(|value| value.into_owned())
        })
        .unwrap_or_default()
}

fn spreadsheet_column_index(reference: &str) -> usize {
    let mut value = 0usize;
    for character in reference
        .chars()
        .take_while(|character| character.is_ascii_alphabetic())
    {
        value = value * 26 + (character.to_ascii_uppercase() as u8 - b'A' + 1) as usize;
    }
    value.saturating_sub(1)
}

fn worksheet_number(name: &str) -> u32 {
    name.rsplit("sheet")
        .next()
        .and_then(|part| part.strip_suffix(".xml"))
        .and_then(|part| part.parse().ok())
        .unwrap_or(u32::MAX)
}

fn xml_text(xml: &str) -> String {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut lines = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::Text(text)) => {
                if let Ok(decoded) = text.decode() {
                    let value = quick_xml::escape::unescape(&decoded)
                        .map(|value| value.into_owned())
                        .unwrap_or_else(|_| decoded.into_owned());
                    let value = value.trim();
                    if !value.is_empty() {
                        lines.push(value.to_string());
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use pdf_extract::content::{Content, Operation};
    use pdf_extract::{Dictionary, Document, Object, Stream};
    use std::fs;
    use std::path::{Path, PathBuf};

    fn write_visual_pdf(path: &Path, background_gray: f32, producer: &str) {
        let mut document = Document::with_version("1.5");
        let pages_id = document.new_object_id();

        let mut font = Dictionary::new();
        font.set("Type", "Font");
        font.set("Subtype", "Type1");
        font.set("BaseFont", "Helvetica");
        let font_id = document.add_object(font);

        let mut fonts = Dictionary::new();
        fonts.set("F1", font_id);
        let mut resources = Dictionary::new();
        resources.set("Font", fonts);
        let resources_id = document.add_object(resources);

        let content = Content {
            operations: vec![
                Operation::new("g", vec![background_gray.into()]),
                Operation::new("re", vec![0.into(), 0.into(), 300.into(), 200.into()]),
                Operation::new("f", vec![]),
                Operation::new("g", vec![0.into()]),
                Operation::new("BT", vec![]),
                Operation::new("Tf", vec!["F1".into(), 18.into()]),
                Operation::new("Td", vec![40.into(), 100.into()]),
                Operation::new("Tj", vec![Object::string_literal("Same text")]),
                Operation::new("ET", vec![]),
            ],
        };
        let content_id = document.add_object(Stream::new(
            Dictionary::new(),
            content.encode().expect("encode PDF content"),
        ));

        let mut page = Dictionary::new();
        page.set("Type", "Page");
        page.set("Parent", pages_id);
        page.set("Contents", content_id);
        let page_id = document.add_object(page);

        let mut pages = Dictionary::new();
        pages.set("Type", "Pages");
        pages.set("Kids", vec![Object::Reference(page_id)]);
        pages.set("Count", 1);
        pages.set("Resources", resources_id);
        pages.set("MediaBox", vec![0.into(), 0.into(), 300.into(), 200.into()]);
        document.objects.insert(pages_id, Object::Dictionary(pages));

        let mut catalog = Dictionary::new();
        catalog.set("Type", "Catalog");
        catalog.set("Pages", pages_id);
        let catalog_id = document.add_object(catalog);
        document.trailer.set("Root", catalog_id);

        let mut info = Dictionary::new();
        info.set("Producer", Object::string_literal(producer));
        info.set(
            "CreationDate",
            Object::string_literal(format!("D:{producer}")),
        );
        let info_id = document.add_object(info);
        document.trailer.set("Info", info_id);
        document.compress();
        document.save(path).expect("save PDF fixture");
    }

    #[test]
    fn pdf_preview_keeps_bytes_and_extracts_text_for_the_agent() {
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../Examples/project-aurora/project-aurora-demo.pdf");
        let preview = preview_file(fixture).expect("fixture PDF should be readable");

        assert_eq!(preview.kind, PreviewKind::Pdf);
        assert!(preview.content.starts_with("data:application/pdf;base64,"));
        assert!(!preview.sections.is_empty());
        assert!(preview.sections.join("\n").contains("Project Aurora"));
        assert!(preview.faithful);
        assert!(!preview.revision.is_empty());
    }

    #[test]
    fn preview_revision_changes_when_same_path_is_overwritten() {
        let fixture = tempfile::Builder::new()
            .prefix("lingshu-preview-revision-")
            .suffix(".txt")
            .tempfile()
            .expect("create revision fixture");
        fs::write(fixture.path(), "first version").expect("write first fixture");
        let first = preview_file(fixture.path()).expect("preview first fixture");
        fs::write(fixture.path(), "second version").expect("overwrite fixture");
        let second = preview_file(fixture.path()).expect("preview overwritten fixture");

        assert_ne!(first.revision, second.revision);
        assert_eq!(second.content, "second version");
    }

    #[test]
    fn pdf_same_text_with_different_visuals_has_different_semantic_revision() {
        let directory = tempfile::tempdir().unwrap();
        let light = directory.path().join("light.pdf");
        let dark = directory.path().join("dark.pdf");
        write_visual_pdf(&light, 0.9, "same-producer");
        write_visual_pdf(&dark, 0.2, "same-producer");

        let light_preview = preview_file(&light).unwrap();
        let dark_preview = preview_file(&dark).unwrap();
        assert_eq!(light_preview.sections, dark_preview.sections);
        assert!(light_preview.sections.join("\n").contains("Same text"));
        assert_ne!(
            semantic_file_revision(&light).unwrap(),
            semantic_file_revision(&dark).unwrap()
        );
    }

    #[test]
    fn pdf_metadata_only_change_keeps_semantic_revision() {
        let directory = tempfile::tempdir().unwrap();
        let first = directory.path().join("first.pdf");
        let second = directory.path().join("second.pdf");
        write_visual_pdf(&first, 0.7, "producer-one");
        write_visual_pdf(&second, 0.7, "producer-two-with-a-different-length");

        assert_ne!(
            file_revision(&first).unwrap(),
            file_revision(&second).unwrap()
        );
        assert_eq!(
            semantic_file_revision(&first).unwrap(),
            semantic_file_revision(&second).unwrap()
        );
    }
}
