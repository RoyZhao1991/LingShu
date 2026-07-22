use base64::Engine;
use quick_xml::events::Event;
use quick_xml::Reader;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{Cursor, Read};
use std::path::Path;
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
    let mut payload = PreviewPayload {
        name,
        path: path.display().to_string(),
        kind: PreviewKind::Unsupported,
        mime_type: "application/octet-stream".into(),
        content: String::new(),
        sections: Vec::new(),
        size_bytes: metadata.len(),
    };
    match ext.as_str() {
        "md" | "markdown" => {
            payload.kind = PreviewKind::Markdown;
            payload.mime_type = "text/markdown".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
        }
        "txt" | "log" | "csv" | "tsv" => {
            payload.kind = PreviewKind::Text;
            payload.mime_type = "text/plain".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
        }
        "json" | "yaml" | "yml" | "toml" | "xml" | "rs" | "swift" | "js" | "ts" | "tsx" | "jsx"
        | "py" | "sh" | "ps1" | "css" => {
            payload.kind = PreviewKind::Code;
            payload.mime_type = "text/plain".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
        }
        "html" | "htm" => {
            payload.kind = PreviewKind::Html;
            payload.mime_type = "text/html".into();
            payload.content = String::from_utf8_lossy(&bytes).into_owned();
        }
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "svg" => {
            payload.kind = PreviewKind::Image;
            payload.mime_type = image_mime(&ext).into();
            payload.content = format!(
                "data:{};base64,{}",
                payload.mime_type,
                base64::engine::general_purpose::STANDARD.encode(bytes)
            );
        }
        "pdf" => {
            payload.kind = PreviewKind::Pdf;
            payload.mime_type = "application/pdf".into();
            payload.content = format!(
                "data:application/pdf;base64,{}",
                base64::engine::general_purpose::STANDARD.encode(bytes)
            );
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
        }
        _ => {}
    }
    Ok(payload)
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
