use crate::models::{ArtifactRecord, ArtifactSpec, SlideSpec};
use chrono::{DateTime, Utc};
use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
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
    fs::create_dir_all(workspace).map_err(ArtifactError::CreateDirectory)?;
    let mut records = Vec::new();
    for spec in specs {
        let file_name = safe_file_name(&spec.file_name, &spec.kind);
        let path = unique_path(workspace.join(file_name));
        let data = match spec.kind.to_ascii_lowercase().as_str() {
            "docx" | "word" => build_docx(&spec.title, &spec.content)?,
            "pptx" | "powerpoint" | "presentation" => build_pptx(&spec.title, &spec.slides)?,
            "html" => html_document(&spec.title, &spec.content).into_bytes(),
            _ => spec.content.as_bytes().to_vec(),
        };
        fs::write(&path, data).map_err(ArtifactError::Write)?;
        let metadata = fs::metadata(&path).map_err(ArtifactError::Write)?;
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
        });
    }
    Ok(records)
}

fn safe_file_name(raw: &str, kind: &str) -> String {
    let extension = match kind.to_ascii_lowercase().as_str() {
        "docx" | "word" => "docx",
        "pptx" | "powerpoint" | "presentation" => "pptx",
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
    for index in 2..1000 {
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
    path
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
                },
            ],
        )
        .unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(
            preview_file(&records[0].path).unwrap().kind,
            PreviewKind::Document
        );
        assert_eq!(
            preview_file(&records[1].path).unwrap().sections[0],
            "Problem\nOne\nTwo"
        );
    }
}
