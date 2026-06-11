import Foundation

extension LingShuEngineeringArtifactService {
    func makePresentationArtifacts(root: URL, stamp: String, prompt: String, reply: String) -> [LingShuMaterializedArtifact] {
        let directory = root.appendingPathComponent("presentation-lingshu-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let slides = presentationSlides(prompt: prompt, reply: reply)
        let htmlURL = directory.appendingPathComponent("lingshu-presentation.html")
        let outlineURL = directory.appendingPathComponent("README.md")
        let pptxURL = directory.appendingPathComponent("lingshu-presentation.pptx")
        var artifacts: [LingShuMaterializedArtifact] = []

        if write(presentationHTML(slides: slides), to: htmlURL) {
            artifacts.append(.init(title: "PPT 演示预览页", location: htmlURL.path, producer: "设计"))
        }

        if write(presentationOutline(slides: slides, prompt: prompt), to: outlineURL) {
            artifacts.append(.init(title: "PPT 结构说明", location: outlineURL.path, producer: "设计"))
        }

        if writePPTX(slides: slides, to: pptxURL) {
            artifacts.append(.init(title: "PPTX 演示文件", location: pptxURL.path, producer: "设计"))
        }

        return artifacts
    }

    private func presentationSlides(prompt: String, reply: String) -> [PresentationSlide] {
        [
            .init(
                title: "灵枢：对话式 AI 中枢",
                subtitle: "把需求转化为可追踪、可验收的工程任务",
                bullets: [
                    "用户只需要提出目标，灵枢负责判断、分派和统一交付。",
                    "普通问题直接回答，工程任务进入能力节点协同。",
                    "每次任务都会沉淀执行记录和产出物清单。"
                ]
            ),
            .init(
                title: "工程推进链路",
                subtitle: "规划、审议、调度、执行、监控、验证",
                bullets: [
                    "规划节点拆解目标与约束，形成可执行路径。",
                    "审议节点同步检查风险、权限和交付边界。",
                    "执行与验证节点产出文件，并回传给灵枢验收。"
                ]
            ),
            .init(
                title: "当前任务交付",
                subtitle: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "演示任务" : prompt,
                bullets: [
                    reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已生成演示页、PPTX 文件和结构说明。" : compact(reply, limit: 82),
                    "产出物会挂载到任务执行记录，便于回看与二次迭代。",
                    "后续可接入设计部、文档部和外部 agent 扩展交付类型。"
                ]
            )
        ]
    }

    private func writePPTX(slides: [PresentationSlide], to pptxURL: URL) -> Bool {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-pptx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try? FileManager.default.removeItem(at: pptxURL)

        guard createPPTXPackage(slides: slides, at: packageURL) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = packageURL
        process.arguments = ["-qr", pptxURL.path, "."]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: pptxURL.path)
    }

    private func createPPTXPackage(slides: [PresentationSlide], at root: URL) -> Bool {
        let directories = [
            root.appendingPathComponent("_rels", isDirectory: true),
            root.appendingPathComponent("docProps", isDirectory: true),
            root.appendingPathComponent("ppt/_rels", isDirectory: true),
            root.appendingPathComponent("ppt/slides/_rels", isDirectory: true),
            root.appendingPathComponent("ppt/slideMasters/_rels", isDirectory: true),
            root.appendingPathComponent("ppt/slideLayouts/_rels", isDirectory: true),
            root.appendingPathComponent("ppt/theme", isDirectory: true)
        ]
        for directory in directories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }

        let writes: [(String, String)] = [
            ("[Content_Types].xml", contentTypesXML(slideCount: slides.count)),
            ("_rels/.rels", rootRelsXML),
            ("docProps/app.xml", appPropertiesXML(slideCount: slides.count)),
            ("docProps/core.xml", corePropertiesXML),
            ("ppt/presentation.xml", presentationXML(slideCount: slides.count)),
            ("ppt/_rels/presentation.xml.rels", presentationRelsXML(slideCount: slides.count)),
            ("ppt/slideMasters/slideMaster1.xml", slideMasterXML),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", slideMasterRelsXML),
            ("ppt/slideLayouts/slideLayout1.xml", slideLayoutXML),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", slideLayoutRelsXML),
            ("ppt/theme/theme1.xml", themeXML)
        ]

        for (path, text) in writes {
            guard write(text, to: root.appendingPathComponent(path)) else { return false }
        }

        for (index, slide) in slides.enumerated() {
            let slideNumber = index + 1
            guard write(slideXML(slide: slide, index: slideNumber), to: root.appendingPathComponent("ppt/slides/slide\(slideNumber).xml")) else {
                return false
            }
            guard write(slideRelsXML, to: root.appendingPathComponent("ppt/slides/_rels/slide\(slideNumber).xml.rels")) else {
                return false
            }
        }

        return true
    }

    private func presentationOutline(slides: [PresentationSlide], prompt: String) -> String {
        let body = slides.enumerated().map { index, slide in
            """
            ## \(index + 1). \(slide.title)
            \(slide.subtitle)
            \(slide.bullets.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
            .joined(separator: "\n\n")

        return """
        # LingShu Presentation Artifact

        ## Task
        \(prompt)

        \(body)
        """
    }

    private func presentationHTML(slides: [PresentationSlide]) -> String {
        let sections = slides.enumerated().map { index, slide in
            """
            <section class="slide">
              <div class="index">0\(index + 1)</div>
              <h1>\(htmlEscape(slide.title))</h1>
              <p class="subtitle">\(htmlEscape(slide.subtitle))</p>
              <ul>
                \(slide.bullets.map { "<li>\(htmlEscape($0))</li>" }.joined(separator: "\n        "))
              </ul>
            </section>
            """
        }
            .joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>LingShu Presentation</title>
          <style>
            :root { color-scheme: dark; --cyan: #25f4e4; --blue: #47a7ff; --ink: #f2fffd; --muted: #9fb8b4; }
            body { margin: 0; min-height: 100vh; background: radial-gradient(circle at 24% 20%, rgba(37,244,228,.2), transparent 28%), #04100f; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; color: var(--ink); }
            main { min-height: 100vh; display: grid; grid-template-columns: repeat(3, minmax(260px, 1fr)); gap: 24px; padding: 42px; box-sizing: border-box; }
            .slide { border: 1px solid rgba(37,244,228,.38); background: linear-gradient(145deg, rgba(9,44,44,.88), rgba(4,14,18,.9)); padding: 28px; min-height: 420px; box-shadow: 0 0 36px rgba(37,244,228,.12); position: relative; overflow: hidden; }
            .slide:before { content: ""; position: absolute; inset: 0; background-image: linear-gradient(rgba(37,244,228,.08) 1px, transparent 1px), linear-gradient(90deg, rgba(37,244,228,.08) 1px, transparent 1px); background-size: 34px 34px; opacity: .35; pointer-events: none; }
            .index { color: var(--cyan); font: 700 14px/1 "SF Mono", monospace; position: relative; z-index: 1; }
            h1 { font-size: 34px; line-height: 1.16; margin: 42px 0 16px; position: relative; z-index: 1; }
            .subtitle { color: var(--cyan); font-size: 17px; font-weight: 700; position: relative; z-index: 1; }
            ul { margin: 34px 0 0; padding-left: 20px; display: grid; gap: 18px; position: relative; z-index: 1; }
            li { color: var(--muted); font-size: 18px; line-height: 1.55; }
            @media (max-width: 960px) { main { grid-template-columns: 1fr; } }
          </style>
        </head>
        <body><main>
        \(sections)
        </main></body>
        </html>
        """
    }

    private struct PresentationSlide {
        var title: String
        var subtitle: String
        var bullets: [String]
    }

    private func contentTypesXML(slideCount: Int) -> String {
        let slideOverrides = (1...slideCount)
            .map { #"<Override PartName="/ppt/slides/slide\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"# }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
          <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
          <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
          <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(slideOverrides)
        </Types>
        """
    }

    private var rootRelsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private func appPropertiesXML(slideCount: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>LingShu</Application>
          <PresentationFormat>On-screen Show (16:9)</PresentationFormat>
          <Slides>\(slideCount)</Slides>
          <Company>LingShu</Company>
        </Properties>
        """
    }

    private var corePropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>LingShu Presentation</dc:title>
          <dc:creator>LingShu</dc:creator>
          <cp:lastModifiedBy>LingShu</cp:lastModifiedBy>
        </cp:coreProperties>
        """
    }

    private func presentationXML(slideCount: Int) -> String {
        let slideIDs = (1...slideCount)
            .map { #"<p:sldId id="\#(255 + $0)" r:id="rId\#($0 + 1)"/>"# }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
          <p:sldIdLst>
        \(slideIDs)
          </p:sldIdLst>
          <p:sldSz cx="12192000" cy="6858000" type="wide"/>
          <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
    }

    private func presentationRelsXML(slideCount: Int) -> String {
        let slideRels = (1...slideCount)
            .map { #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#($0).xml"/>"# }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        \(slideRels)
        </Relationships>
        """
    }

    private var slideMasterXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
          <p:clrMap bg1="dk1" tx1="lt1" bg2="dk2" tx2="lt2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
          <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
          <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles>
        </p:sldMaster>
        """
    }

    private var slideMasterRelsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
    }

    private var slideLayoutXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
          <p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
          <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
    }

    private var slideLayoutRelsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
    }

    private var slideRelsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        </Relationships>
        """
    }

    private var themeXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="LingShu">
          <a:themeElements>
            <a:clrScheme name="LingShu">
              <a:dk1><a:srgbClr val="04100F"/></a:dk1><a:lt1><a:srgbClr val="F2FFFD"/></a:lt1>
              <a:dk2><a:srgbClr val="0A2423"/></a:dk2><a:lt2><a:srgbClr val="B7D5D0"/></a:lt2>
              <a:accent1><a:srgbClr val="25F4E4"/></a:accent1><a:accent2><a:srgbClr val="47A7FF"/></a:accent2>
              <a:accent3><a:srgbClr val="FF9A2A"/></a:accent3><a:accent4><a:srgbClr val="37D67A"/></a:accent4>
              <a:accent5><a:srgbClr val="B55CFF"/></a:accent5><a:accent6><a:srgbClr val="FF4D67"/></a:accent6>
              <a:hlink><a:srgbClr val="25F4E4"/></a:hlink><a:folHlink><a:srgbClr val="B55CFF"/></a:folHlink>
            </a:clrScheme>
            <a:fontScheme name="LingShu"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface="PingFang SC"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface="PingFang SC"/></a:minorFont></a:fontScheme>
            <a:fmtScheme name="LingShu"><a:fillStyleLst/><a:lnStyleLst/><a:effectStyleLst/><a:bgFillStyleLst/></a:fmtScheme>
          </a:themeElements>
        </a:theme>
        """
    }

    private func slideXML(slide: PresentationSlide, index: Int) -> String {
        let bulletParagraphs = slide.bullets.enumerated().map { bulletIndex, bullet in
            """
              <a:p>
                <a:pPr marL="260000" indent="-180000"><a:buChar char="•"/></a:pPr>
                <a:r><a:rPr lang="zh-CN" sz="2300"><a:solidFill><a:srgbClr val="B7D5D0"/></a:solidFill></a:rPr><a:t>\(xmlEscape(bullet))</a:t></a:r>
                <a:endParaRPr lang="zh-CN" sz="2300"/>
              </a:p>
            """
        }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld>
            <p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Background"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="6858000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="04100F"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Accent"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="720000" y="660000"/><a:ext cx="10750000" cy="5200000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="092C2C"><a:alpha val="72000"/></a:srgbClr></a:solidFill><a:ln w="16000"><a:solidFill><a:srgbClr val="25F4E4"/></a:solidFill></a:ln></p:spPr>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="4" name="Index"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="960000" y="900000"/><a:ext cx="1100000" cy="360000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="1600" b="1"><a:solidFill><a:srgbClr val="25F4E4"/></a:solidFill></a:rPr><a:t>0\(index)</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="5" name="Title"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="960000" y="1350000"/><a:ext cx="10200000" cy="980000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="4000" b="1"><a:solidFill><a:srgbClr val="F2FFFD"/></a:solidFill></a:rPr><a:t>\(xmlEscape(slide.title))</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="6" name="Subtitle"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="980000" y="2500000"/><a:ext cx="9800000" cy="520000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="2000" b="1"><a:solidFill><a:srgbClr val="25F4E4"/></a:solidFill></a:rPr><a:t>\(xmlEscape(slide.subtitle))</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="7" name="Bullets"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="1220000" y="3300000"/><a:ext cx="9600000" cy="2200000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
                <p:txBody><a:bodyPr wrap="square"/><a:lstStyle/>
        \(bulletParagraphs)
                </p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
          <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private func compact(_ text: String, limit: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return "\(cleaned.prefix(limit))..."
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func xmlEscape(_ value: String) -> String {
        htmlEscape(value).replacingOccurrences(of: "'", with: "&apos;")
    }
}
