import Foundation

struct LingShuMaterializedArtifact: Equatable {
    var title: String
    var location: String
    var producer: String
}

struct LingShuEngineeringArtifactService {
    enum Capability: Equatable {
        case software
        case presentation
        case document
    }

    func inferCapabilities(prompt: String, route: CodexRoutePayload? = nil) -> [Capability] {
        let routeText = route.map { route in
            (
                [route.summary, route.currentReply, route.executionRequest, route.directAnswer, route.finalAnswer].compactMap { $0 }
                + route.agents.flatMap { [$0.agent, $0.task, $0.mode] }.compactMap { $0 }
            )
                .joined(separator: " ")
        } ?? ""
        let text = "\(prompt) \(routeText)".lowercased()
        var capabilities: [Capability] = []

        if text.contains("ppt")
            || text.contains("pptx")
            || text.contains("powerpoint")
            || text.contains("幻灯片")
            || text.contains("演示")
            || text.contains("汇报")
            || text.contains("陈述")
            || text.contains("deck") {
            capabilities.append(.presentation)
        }

        // 明确点名文件格式/文件名时直接触发；泛文档名词（文档/报告/资料等）须配合生成动词，
        // 避免“查个资料”“看下这份报告”这类非生成请求误产出一堆文件。
        let explicitFileSignal = text.contains(".md")
            || text.contains(".txt")
            || text.contains(".html")
            || text.contains(".json")
            || text.contains(".csv")
            || text.contains("readme")
            || text.contains("本地文件")
        let documentSignal = text.contains("markdown")
            || text.contains("pdf")
            || text.contains("txt")
            || text.contains("html")
            || text.contains("json")
            || text.contains("csv")
            || text.contains("文档")
            || text.contains("报告")
            || text.contains("说明书")
            || text.contains("手册")
            || text.contains("资料")
            || text.contains("表格")
            || text.contains("清单")
        let generationVerb = text.contains("生成")
            || text.contains("做一") || text.contains("做个") || text.contains("帮我做")
            || text.contains("写一") || text.contains("写个") || text.contains("帮我写")
            || text.contains("编写") || text.contains("制作") || text.contains("导出")
            || text.contains("整理") || text.contains("出一") || text.contains("给我一")
        if explicitFileSignal || (documentSignal && generationVerb) {
            capabilities.append(.document)
        }

        // 只有"确实是爬虫/网页抓取"才套爬虫模板产物；泛指的"代码/脚本"不再误触发——
        // 那类任务的真实文件由协同管线的 agentic 工具执行直接写出（见 materializeTaskArtifacts），
        // 不该再硬塞一份不相关的爬虫 demo（曾导致"写 hello.py"产出 crawler.py 的错配）。
        if text.contains("爬虫")
            || text.contains("crawler")
            || text.contains("spider")
            || text.contains("web scrape")
            || text.contains("网页抓取") {
            capabilities.append(.software)
        }

        return capabilities
    }

    func materializeArtifacts(
        prompt: String,
        route: CodexRoutePayload? = nil,
        reply: String,
        workingDirectory: String,
        now: Date = Date()
    ) -> [LingShuMaterializedArtifact] {
        let capabilities = inferCapabilities(prompt: prompt, route: route)
        guard !capabilities.isEmpty else { return [] }

        let root = artifactRoot(workingDirectory: workingDirectory)
        let stamp = artifactStamp(from: now)
        var artifacts: [LingShuMaterializedArtifact] = []

        for capability in capabilities {
            switch capability {
            case .software:
                artifacts.append(contentsOf: makeCrawlerArtifacts(root: root, stamp: stamp, prompt: prompt, reply: reply))
            case .presentation:
                artifacts.append(contentsOf: makePresentationArtifacts(root: root, stamp: stamp, prompt: prompt, reply: reply))
            case .document:
                artifacts.append(contentsOf: makeDocumentArtifacts(root: root, stamp: stamp, prompt: prompt, reply: reply))
            }
        }

        if !artifacts.isEmpty {
            let manifestURL = root.appendingPathComponent("artifact-manifest-\(stamp).json")
            let manifestText = manifestJSON(prompt: prompt, artifacts: artifacts, now: now)
            if write(manifestText, to: manifestURL) {
                artifacts.append(.init(title: "产出物清单", location: manifestURL.path, producer: "产出物"))
            }
        }

        return artifacts
    }

    private func artifactRoot(workingDirectory: String) -> URL {
        let base = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("app", isDirectory: true)
            : URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let projectRoot = base.appendingPathComponent("LingShuMac", isDirectory: true)
        let root = (FileManager.default.fileExists(atPath: projectRoot.path) ? projectRoot : base)
            .appendingPathComponent("ValidationArtifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func artifactStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
