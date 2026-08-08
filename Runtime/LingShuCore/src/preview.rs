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
    use std::path::PathBuf;

    #[test]
    fn pdf_preview_keeps_bytes_and_extracts_text_for_the_agent() {
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../Examples/project-aurora/project-aurora-demo.pdf");
        let preview = preview_file(fixture).expect("fixture PDF should be readable");

        assert_eq!(preview.kind, PreviewKind::Pdf);
        assert!(preview.content.starts_with("data:application/pdf;base64,"));
        assert!(!preview.sections.is_empty());
        assert!(preview.sections.join("\n").contains("Project Aurora"));
    }
}
