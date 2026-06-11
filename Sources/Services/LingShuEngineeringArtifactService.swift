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
    }

    func inferCapabilities(prompt: String, route: CodexRoutePayload? = nil) -> [Capability] {
        let routeText = route.map { route in
            ([route.summary, route.directAnswer, route.finalAnswer].compactMap { $0 } + route.agents.flatMap { [$0.agent, $0.task, $0.mode] }.compactMap { $0 })
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

        if text.contains("爬虫")
            || text.contains("crawler")
            || text.contains("spider")
            || text.contains("web scrape")
            || text.contains("网页抓取")
            || text.contains("代码")
            || text.contains("脚本") {
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
