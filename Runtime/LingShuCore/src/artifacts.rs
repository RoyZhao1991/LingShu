use crate::models::{ArtifactRecord, ArtifactSpec, SheetSpec, SlideSpec};
use crate::preview::{content_revision, semantic_file_revision_cancellable};
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::fs;
use std::io::{Cursor, Write};
use std::path::{Component, Path, PathBuf};
use thiserror::Error;
use uuid::Uuid;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

#[derive(Debug, Error)]
pub enum ArtifactError {
    #[error("could not create artifact directory: {0}")]
    CreateDirectory(#[source] std::io::Error),
    #[error("could not write artifact: {0}")]
    Write(#[source] std::io::Error),
    #[error("could not build Office document: {0}")]
    Zip(#[from] zip::result::ZipError),
}

pub fn materialize_artifacts(
    workspace: &Path,
    specs: &[ArtifactSpec],
) -> Result<Vec<ArtifactRecord>, ArtifactError> {
    materialize_artifacts_cancellable(workspace, specs, &|| false)
}

pub(crate) fn materialize_artifacts_cancellable(
    workspace: &Path,
    specs: &[ArtifactSpec],
    cancelled: &dyn Fn() -> bool,
) -> Result<Vec<ArtifactRecord>, ArtifactError> {
    fs::create_dir_all(workspace).map_err(ArtifactError::CreateDirectory)?;
    let mut records = Vec::new();
    for spec in specs {
        if cancelled() {
            return Err(ArtifactError::Write(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "artifact materialization was cancelled",
            )));
        }
        let file_name = safe_file_name(&spec.file_name, &spec.kind);
        let path = unique_path(workspace.join(file_name));
        let data = match spec.kind.to_ascii_lowercase().as_str() {
            "docx" | "word" => build_docx(&spec.title, &spec.content)?,
            "pptx" | "powerpoint" | "presentation" => build_pptx(&spec.title, &spec.slides)?,
            "xlsx" | "excel" | "spreadsheet" => {
                build_xlsx(&spec.title, &spec.content, &spec.sheets)?
            }
            "html" => html_document(&spec.title, &spec.content).into_bytes(),
            _ => spec.content.as_bytes().to_vec(),
        };
        let revision = content_revision(&data);
        fs::write(&path, &data).map_err(ArtifactError::Write)?;
        let metadata = fs::metadata(&path).map_err(ArtifactError::Write)?;
        let semantic_revision =
            semantic_file_revision_cancellable(&path, cancelled).map_err(|error| {
                ArtifactError::Write(match error {
                    crate::preview::PreviewError::Read(error) => error,
                    other => std::io::Error::other(other.to_string()),
                })
            })?;
        let modified_at = metadata
            .modified()
            .ok()
            .map(DateTime::<Utc>::from)
            .unwrap_or_else(Utc::now);
        records.push(ArtifactRecord {
            id: Uuid::new_v4(),
            title: spec.title.clone(),
            path,
            kind: spec.kind.clone(),
            size_bytes: metadata.len(),
            modified_at,
            logical_key: Some(create_artifact_logical_key(&spec.file_name, &spec.kind)),
            revision,
            semantic_revision,
            semantic_context: String::new(),
            supersedes: None,
            superseded_by: None,
        });
    }
    Ok(records)
}

pub(crate) fn safe_file_name(raw: &str, kind: &str) -> String {
    let extension = match kind.to_ascii_lowercase().as_str() {
        "docx" | "word" => "docx",
        "pptx" | "powerpoint" | "presentation" => "pptx",
        "xlsx" | "excel" | "spreadsheet" => "xlsx",
        "html" => "html",
        "markdown" | "md" => "md",
        "json" => "json",
        _ => "txt",
    };
    let mut name: String = raw
        .chars()
        .map(|character| {
            if "<>:\"/\\|?*".contains(character) || character.is_control() {
                '_'
            } else {
                character
            }
        })
        .collect();
    name = name.trim().trim_matches('.').to_string();
    if name.is_empty() {
        name = "LingShu-Artifact".into();
    }
    if Path::new(&name)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.eq_ignore_ascii_case(extension))
        != Some(true)
    {
        name.push('.');
        name.push_str(extension);
    }
    name
}

pub(crate) fn create_artifact_logical_key(file_name: &str, kind: &str) -> String {
    format!("create:{}", safe_file_name(file_name, kind))
}

pub(crate) fn artifact_path_logical_key(path: &Path) -> String {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    format!("path:{}", normalized.display())
}

fn unique_path(path: PathBuf) -> PathBuf {
    if !path.exists() {
        return path;
    }
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("artifact");
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    for index in 2_u64.. {
        let suffix = if extension.is_empty() {
            format!("{stem}-{index}")
        } else {
            format!("{stem}-{index}.{extension}")
        };
        let candidate = parent.join(suffix);
        if !candidate.exists() {
            return candidate;
        }
    }
    unreachable!("an unbounded numeric suffix always has another candidate")
}

fn options() -> SimpleFileOptions {
    SimpleFileOptions::default().compression_method(CompressionMethod::Deflated)
}

fn add_file(
    zip: &mut ZipWriter<Cursor<Vec<u8>>>,
    path: &str,
    content: &str,
) -> Result<(), ArtifactError> {
    zip.start_file(path, options())?;
    zip.write_all(content.as_bytes())
        .map_err(ArtifactError::Write)
}

fn build_docx(title: &str, content: &str) -> Result<Vec<u8>, ArtifactError> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    add_file(&mut zip, "[Content_Types].xml", DOCX_CONTENT_TYPES)?;
    add_file(&mut zip, "_rels/.rels", DOCX_ROOT_RELS)?;
    add_file(&mut zip, "docProps/app.xml", DOCX_APP)?;
    add_file(&mut zip, "docProps/core.xml", &core_properties(title))?;
    add_file(&mut zip, "word/styles.xml", DOCX_STYLES)?;
    add_file(&mut zip, "word/_rels/document.xml.rels", DOCX_DOCUMENT_RELS)?;
    add_file(
        &mut zip,
        "word/document.xml",
        &docx_document(title, content),
    )?;
    Ok(zip.finish()?.into_inner())
}

fn build_xlsx(title: &str, content: &str, sheets: &[SheetSpec]) -> Result<Vec<u8>, ArtifactError> {
    let sheets = normalized_sheets(title, content, sheets);
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    add_file(
        &mut zip,
        "[Content_Types].xml",
        &xlsx_content_types(sheets.len()),
    )?;
    add_file(&mut zip, "_rels/.rels", XLSX_ROOT_RELS)?;
    add_file(&mut zip, "docProps/app.xml", &xlsx_app(&sheets))?;
    add_file(&mut zip, "docProps/core.xml", &core_properties(title))?;
    add_file(&mut zip, "xl/workbook.xml", &xlsx_workbook(&sheets))?;
    add_file(
        &mut zip,
        "xl/_rels/workbook.xml.rels",
        &xlsx_workbook_rels(sheets.len()),
    )?;
    add_file(&mut zip, "xl/styles.xml", XLSX_STYLES)?;
    for (index, sheet) in sheets.iter().enumerate() {
        add_file(
            &mut zip,
            &format!("xl/worksheets/sheet{}.xml", index + 1),
            &xlsx_sheet(sheet),
        )?;
    }
    Ok(zip.finish()?.into_inner())
}

fn normalized_sheets(title: &str, content: &str, sheets: &[SheetSpec]) -> Vec<SheetSpec> {
    if !sheets.is_empty() {
        let mut used = Vec::new();
        return sheets
            .iter()
            .enumerate()
            .map(|(index, sheet)| {
                let name = unique_sheet_name(&sheet.name, index, &used);
                used.push(name.clone());
                SheetSpec {
                    name,
                    rows: sheet.rows.clone(),
                }
            })
            .collect();
    }
    let delimiter = if content.contains('\t') { '\t' } else { ',' };
    let rows = content
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            line.split(delimiter)
                .map(|cell| Value::String(cell.trim().to_string()))
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    vec![SheetSpec {
        name: unique_sheet_name(title, 0, &[]),
        rows: if rows.is_empty() {
            vec![vec![Value::String(title.to_string())]]
        } else {
            rows
        },
    }]
}

fn unique_sheet_name(raw: &str, index: usize, used: &[String]) -> String {
    let mut base = raw
        .chars()
        .filter(|character| !"[]:*?/\\".contains(*character) && !character.is_control())
        .collect::<String>();
    base = base.trim().trim_matches('\'').chars().take(31).collect();
    if base.is_empty() {
        base = format!("Sheet {}", index + 1);
    }
    let mut candidate = base.clone();
    let mut suffix = 2;
    while used
        .iter()
        .any(|name| name.eq_ignore_ascii_case(&candidate))
    {
        let tail = format!(" ({suffix})");
        let keep = 31usize.saturating_sub(tail.chars().count());
        candidate = format!("{}{}", base.chars().take(keep).collect::<String>(), tail);
        suffix += 1;
    }
    candidate
}

fn xlsx_sheet(sheet: &SheetSpec) -> String {
    let max_columns = sheet.rows.iter().map(Vec::len).max().unwrap_or(1).max(1);
    let max_rows = sheet.rows.len().max(1);
    let rows = sheet
        .rows
        .iter()
        .enumerate()
        .map(|(row_index, row)| {
            let cells = row
                .iter()
                .enumerate()
                .map(|(column_index, value)| {
                    xlsx_cell(value, column_index, row_index, row_index == 0)
                })
                .collect::<String>();
            format!("<row r=\"{}\">{cells}</row>", row_index + 1)
        })
        .collect::<String>();
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><dimension ref=\"A1:{}{}\"/><sheetViews><sheetView workbookViewId=\"0\"/></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/><sheetData>{rows}</sheetData><pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/></worksheet>",
        spreadsheet_column_name(max_columns - 1),
        max_rows
    )
}

fn xlsx_cell(value: &Value, column: usize, row: usize, header: bool) -> String {
    let reference = format!("{}{}", spreadsheet_column_name(column), row + 1);
    let style = if header { " s=\"1\"" } else { "" };
    match value {
        Value::Null => format!("<c r=\"{reference}\"{style}/>"),
        Value::Bool(value) => format!(
            "<c r=\"{reference}\" t=\"b\"{style}><v>{}</v></c>",
            if *value { 1 } else { 0 }
        ),
        Value::Number(value) => {
            format!("<c r=\"{reference}\"{style}><v>{value}</v></c>")
        }
        Value::String(value) if value.starts_with('=') && value.len() > 1 => format!(
            "<c r=\"{reference}\"{style}><f>{}</f><v>0</v></c>",
            xml_escape(&value[1..])
        ),
        Value::String(value) => xlsx_inline_string(&reference, style, value),
        value => xlsx_inline_string(&reference, style, &value.to_string()),
    }
}

fn xlsx_inline_string(reference: &str, style: &str, value: &str) -> String {
    format!(
        "<c r=\"{reference}\" t=\"inlineStr\"{style}><is><t xml:space=\"preserve\">{}</t></is></c>",
        xml_escape(value)
    )
}

fn spreadsheet_column_name(mut index: usize) -> String {
    let mut name = String::new();
    loop {
        name.insert(0, (b'A' + (index % 26) as u8) as char);
        if index < 26 {
            return name;
        }
        index = index / 26 - 1;
    }
}

fn xlsx_content_types(sheet_count: usize) -> String {
    let sheets = (1..=sheet_count)
        .map(|number| format!("<Override PartName=\"/xl/worksheets/sheet{number}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"))
        .collect::<String>();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>{sheets}</Types>")
}

fn xlsx_workbook(sheets: &[SheetSpec]) -> String {
    let items = sheets
        .iter()
        .enumerate()
        .map(|(index, sheet)| {
            format!(
                "<sheet name=\"{}\" sheetId=\"{}\" r:id=\"rId{}\"/>",
                xml_escape(&sheet.name),
                index + 1,
                index + 1
            )
        })
        .collect::<String>();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><bookViews><workbookView/></bookViews><sheets>{items}</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\" forceFullCalc=\"1\"/></workbook>")
}

fn xlsx_workbook_rels(sheet_count: usize) -> String {
    let sheets = (1..=sheet_count)
        .map(|number| format!("<Relationship Id=\"rId{number}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{number}.xml\"/>"))
        .collect::<String>();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">{sheets}<Relationship Id=\"rId{}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>", sheet_count + 1)
}

fn xlsx_app(sheets: &[SheetSpec]) -> String {
    let titles = sheets
        .iter()
        .map(|sheet| format!("<vt:lpstr>{}</vt:lpstr>", xml_escape(&sheet.name)))
        .collect::<String>();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><Application>LingShu</Application><Company>Roy Zhao</Company><AppVersion>1.0</AppVersion><TitlesOfParts><vt:vector size=\"{}\" baseType=\"lpstr\">{titles}</vt:vector></TitlesOfParts></Properties>", sheets.len())
}

fn docx_document(title: &str, content: &str) -> String {
    let mut paragraphs = vec![format!(
        "<w:p><w:pPr><w:pStyle w:val=\"Title\"/></w:pPr><w:r><w:t>{}</w:t></w:r></w:p>",
        xml_escape(title)
    )];
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            paragraphs.push("<w:p/>".into());
            continue;
        }
        let (style, text) = if let Some(text) = trimmed.strip_prefix("### ") {
            ("Heading3", text)
        } else if let Some(text) = trimmed.strip_prefix("## ") {
            ("Heading2", text)
        } else if let Some(text) = trimmed.strip_prefix("# ") {
            ("Heading1", text)
        } else {
            (
                "Normal",
                trimmed.trim_start_matches("- ").trim_start_matches("* "),
            )
        };
        paragraphs.push(format!(
            "<w:p><w:pPr><w:pStyle w:val=\"{style}\"/></w:pPr><w:r><w:t xml:space=\"preserve\">{}</w:t></w:r></w:p>",
            xml_escape(text)
        ));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>{}<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\"/></w:sectPr></w:body></w:document>",
        paragraphs.join("")
    )
}

fn build_pptx(title: &str, slides: &[SlideSpec]) -> Result<Vec<u8>, ArtifactError> {
    let normalized = if slides.is_empty() {
        vec![SlideSpec {
            title: title.into(),
            bullets: vec!["Created by LingShu".into()],
            notes: String::new(),
        }]
    } else {
        slides.to_vec()
    };
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    add_file(
        &mut zip,
        "[Content_Types].xml",
        &pptx_content_types(normalized.len()),
    )?;
    add_file(&mut zip, "_rels/.rels", PPTX_ROOT_RELS)?;
    add_file(&mut zip, "docProps/app.xml", &pptx_app(normalized.len()))?;
    add_file(&mut zip, "docProps/core.xml", &core_properties(title))?;
    add_file(
        &mut zip,
        "ppt/presentation.xml",
        &pptx_presentation(normalized.len()),
    )?;
    add_file(
        &mut zip,
        "ppt/_rels/presentation.xml.rels",
        &pptx_presentation_rels(normalized.len()),
    )?;
    add_file(&mut zip, "ppt/presProps.xml", PPTX_PRES_PROPS)?;
    add_file(&mut zip, "ppt/viewProps.xml", PPTX_VIEW_PROPS)?;
    add_file(&mut zip, "ppt/tableStyles.xml", PPTX_TABLE_STYLES)?;
    add_file(&mut zip, "ppt/theme/theme1.xml", PPTX_THEME)?;
    add_file(
        &mut zip,
        "ppt/slideMasters/slideMaster1.xml",
        PPTX_SLIDE_MASTER,
    )?;
    add_file(
        &mut zip,
        "ppt/slideMasters/_rels/slideMaster1.xml.rels",
        PPTX_SLIDE_MASTER_RELS,
    )?;
    add_file(
        &mut zip,
        "ppt/slideLayouts/slideLayout1.xml",
        PPTX_SLIDE_LAYOUT,
    )?;
    add_file(
        &mut zip,
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
        PPTX_SLIDE_LAYOUT_RELS,
    )?;
    for (offset, slide) in normalized.iter().enumerate() {
        let number = offset + 1;
        add_file(
            &mut zip,
            &format!("ppt/slides/slide{number}.xml"),
            &pptx_slide(slide, number),
        )?;
        add_file(
            &mut zip,
            &format!("ppt/slides/_rels/slide{number}.xml.rels"),
            PPTX_SLIDE_RELS,
        )?;
    }
    Ok(zip.finish()?.into_inner())
}

fn pptx_slide(slide: &SlideSpec, number: usize) -> String {
    let bullets = slide.bullets.iter().map(|bullet| format!(
        "<a:p><a:pPr marL=\"342900\" indent=\"-285750\"><a:buChar char=\"•\"/></a:pPr><a:r><a:rPr lang=\"zh-CN\" sz=\"2200\"/><a:t>{}</a:t></a:r><a:endParaRPr lang=\"zh-CN\" sz=\"2200\"/></a:p>",
        xml_escape(bullet)
    )).collect::<String>();
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld name=\"Slide {number}\"><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"F7FAFA\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"685800\" y=\"457200\"/><a:ext cx=\"10820400\" cy=\"914400\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"zh-CN\" sz=\"3000\" b=\"1\"><a:solidFill><a:srgbClr val=\"132A2A\"/></a:solidFill></a:rPr><a:t>{}</a:t></a:r><a:endParaRPr lang=\"zh-CN\" sz=\"3000\"/></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Content\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"914400\" y=\"1600200\"/><a:ext cx=\"10058400\" cy=\"4572000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap=\"square\"/><a:lstStyle/>{bullets}</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>",
        xml_escape(&slide.title)
    )
}

fn pptx_content_types(slide_count: usize) -> String {
    let slides = (1..=slide_count).map(|number| format!("<Override PartName=\"/ppt/slides/slide{number}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>")).collect::<String>();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/><Override PartName=\"/ppt/presProps.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presProps+xml\"/><Override PartName=\"/ppt/viewProps.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml\"/><Override PartName=\"/ppt/tableStyles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>{slides}</Types>")
}

fn pptx_presentation(slide_count: usize) -> String {
    let slides = (1..=slide_count)
        .map(|number| {
            format!(
                "<p:sldId id=\"{}\" r:id=\"rId{}\"/>",
                255 + number,
                number + 1
            )
        })
        .collect::<String>();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>{slides}</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\" type=\"screen16x9\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
}

fn pptx_presentation_rels(slide_count: usize) -> String {
    let slides = (1..=slide_count).map(|number| format!("<Relationship Id=\"rId{}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide{number}.xml\"/>", number + 1)).collect::<String>();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>{slides}</Relationships>")
}

fn pptx_app(slide_count: usize) -> String {
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><Application>LingShu</Application><PresentationFormat>On-screen Show (16:9)</PresentationFormat><Slides>{slide_count}</Slides><Notes>0</Notes><HiddenSlides>0</HiddenSlides><MMClips>0</MMClips><ScaleCrop>false</ScaleCrop><Company>Roy Zhao</Company><AppVersion>1.0</AppVersion></Properties>")
}

fn core_properties(title: &str) -> String {
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>{}</dc:title><dc:creator>LingShu</dc:creator><cp:lastModifiedBy>LingShu</cp:lastModifiedBy><dcterms:created xsi:type=\"dcterms:W3CDTF\">{now}</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">{now}</dcterms:modified></cp:coreProperties>", xml_escape(title))
}

fn html_document(title: &str, content: &str) -> String {
    format!("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>{}</title><style>body{{font:16px/1.65 system-ui,sans-serif;max-width:960px;margin:48px auto;padding:0 24px;color:#182323}}h1,h2,h3{{color:#0a7d73}}pre{{white-space:pre-wrap;background:#f1f5f4;padding:16px}}</style></head><body><h1>{}</h1><pre>{}</pre></body></html>", xml_escape(title), xml_escape(title), xml_escape(content))
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

const XLSX_ROOT_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>";
const XLSX_STYLES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><color theme=\"1\"/><name val=\"Aptos\"/><family val=\"2\"/></font><font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Aptos\"/><family val=\"2\"/></font></fonts><fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF0A9B8E\"/><bgColor indexed=\"64\"/></patternFill></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>";
const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/></Types>";
const DOCX_ROOT_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>";
const DOCX_DOCUMENT_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>";
const DOCX_APP: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>LingShu</Application><Company>Roy Zhao</Company><AppVersion>1.0</AppVersion></Properties>";
const DOCX_STYLES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:rPr><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:b/><w:color w:val=\"0A7D73\"/><w:sz w:val=\"40\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:b/><w:color w:val=\"0A7D73\"/><w:sz w:val=\"32\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:b/><w:sz w:val=\"28\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading3\"><w:name w:val=\"heading 3\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:b/><w:sz w:val=\"24\"/></w:rPr></w:style></w:styles>";
const PPTX_ROOT_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>";
const PPTX_SLIDE_MASTER_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/></Relationships>";
const PPTX_SLIDE_LAYOUT_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>";
const PPTX_SLIDE_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>";
const PPTX_SLIDE_MASTER: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sldMaster xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"1\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>";
const PPTX_SLIDE_LAYOUT: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sldLayout xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" type=\"blank\"><p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>";
const PPTX_THEME: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"LingShu\"><a:themeElements><a:clrScheme name=\"LingShu\"><a:dk1><a:srgbClr val=\"182323\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"1F4542\"/></a:dk2><a:lt2><a:srgbClr val=\"F2F7F6\"/></a:lt2><a:accent1><a:srgbClr val=\"0A9B8E\"/></a:accent1><a:accent2><a:srgbClr val=\"2F6FED\"/></a:accent2><a:accent3><a:srgbClr val=\"F49A43\"/></a:accent3><a:accent4><a:srgbClr val=\"42B883\"/></a:accent4><a:accent5><a:srgbClr val=\"7868E6\"/></a:accent5><a:accent6><a:srgbClr val=\"E15C64\"/></a:accent6><a:hlink><a:srgbClr val=\"2F6FED\"/></a:hlink><a:folHlink><a:srgbClr val=\"7868E6\"/></a:folHlink></a:clrScheme><a:fontScheme name=\"LingShu\"><a:majorFont><a:latin typeface=\"Aptos Display\"/><a:ea typeface=\"Microsoft YaHei\"/><a:cs typeface=\"Arial\"/></a:majorFont><a:minorFont><a:latin typeface=\"Aptos\"/><a:ea typeface=\"Microsoft YaHei\"/><a:cs typeface=\"Arial\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"LingShu\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>";
const PPTX_PRES_PROPS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><p:presentationPr xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"/>";
const PPTX_VIEW_PROPS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><p:viewPr xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" lastView=\"sldView\"><p:normalViewPr/><p:slideViewPr/><p:notesTextViewPr/></p:viewPr>";
const PPTX_TABLE_STYLES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a:tblStyleLst xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>";

#[cfg(test)]
mod tests {
    use super::*;
    use crate::preview::{preview_file, PreviewKind};
    use serde_json::json;
    use tempfile::tempdir;

    #[test]
    fn generated_office_files_are_valid_packages_and_previewable() {
        let dir = tempdir().unwrap();
        let records = materialize_artifacts(
            dir.path(),
            &[
                ArtifactSpec {
                    title: "Report".into(),
                    file_name: "report.docx".into(),
                    kind: "docx".into(),
                    content: "# Section\nBody".into(),
                    slides: vec![],
                    sheets: vec![],
                },
                ArtifactSpec {
                    title: "Deck".into(),
                    file_name: "deck.pptx".into(),
                    kind: "pptx".into(),
                    content: String::new(),
                    slides: vec![SlideSpec {
                        title: "Problem".into(),
                        bullets: vec!["One".into(), "Two".into()],
                        notes: String::new(),
                    }],
                    sheets: vec![],
                },
                ArtifactSpec {
                    title: "Metrics".into(),
                    file_name: "metrics.xlsx".into(),
                    kind: "xlsx".into(),
                    content: String::new(),
                    slides: vec![],
                    sheets: vec![SheetSpec {
                        name: "Summary".into(),
                        rows: vec![
                            vec![json!("Metric"), json!("Value"), json!("Verified")],
                            vec![json!("Revenue"), json!(120), json!(true)],
                        ],
                    }],
                },
            ],
        )
        .unwrap();
        assert_eq!(records.len(), 3);
        assert_eq!(
            preview_file(&records[0].path).unwrap().kind,
            PreviewKind::Document
        );
        assert_eq!(
            preview_file(&records[1].path).unwrap().sections[0],
            "Problem\nOne\nTwo"
        );
        let spreadsheet = preview_file(&records[2].path).unwrap();
        assert_eq!(spreadsheet.kind, PreviewKind::Spreadsheet);
        assert!(spreadsheet.content.contains("Summary"));
        assert!(spreadsheet.content.contains("Revenue\t120\tTRUE"));
    }

    #[test]
    fn office_semantic_revision_ignores_container_and_core_timestamp_noise() {
        let dir = tempdir().unwrap();
        let spec = ArtifactSpec {
            title: "Stable report".into(),
            file_name: "stable-report.docx".into(),
            kind: "docx".into(),
            content: "Same audience-facing content.".into(),
            slides: vec![],
            sheets: vec![],
        };
        let first = materialize_artifacts(dir.path(), std::slice::from_ref(&spec))
            .unwrap()
            .remove(0);
        std::thread::sleep(std::time::Duration::from_millis(1_100));
        let second = materialize_artifacts(dir.path(), std::slice::from_ref(&spec))
            .unwrap()
            .remove(0);

        assert_ne!(first.path, second.path);
        assert_ne!(first.revision, second.revision);
        assert_eq!(first.semantic_revision, second.semantic_revision);

        let mut changed = spec;
        changed.content = "Materially changed audience-facing content.".into();
        let changed = materialize_artifacts(dir.path(), &[changed])
            .unwrap()
            .remove(0);
        assert_ne!(first.semantic_revision, changed.semantic_revision);
    }
}
