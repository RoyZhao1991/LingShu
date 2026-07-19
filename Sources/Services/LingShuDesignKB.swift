import Foundation

/// 设计知识库(DesignKB)定位器——自进化高质量 PPT 模块的"会进化的数据/素材"层。
///
/// 内容:`generator.py`(设计系统驱动的多版式生成器)、`palettes.json`/`typography.json`/`layouts.json`
/// (配色/字体/版式原型)、`rubric.md`(设计质量评审清单)、`icons/`(Lucide 等开源图标,预栅格化 PNG)。
/// Phase A:随包只读读取(`Resources/DesignKB`,ditto 进 bundle);生成器在此目录就地跑、自动读同目录素材。
/// Phase C(dreaming 设计轨)会在此之上加**可写 overlay**(app-support),让进化的数据热加载而不动随包种子。
enum LingShuDesignKB {
    static let directoryName = "DesignKB"

    /// 解析 DesignKB 目录:优先 app 包内资源,回退开发源码树。仅返回真实存在的目录。
    static func directoryURL(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        var roots: [URL] = []
        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL.appendingPathComponent(directoryName, isDirectory: true))
        }
        roots.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/\(directoryName)", isDirectory: true)
        )
        roots.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(directoryName)", isDirectory: true)
        )
        return roots.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// DesignKB 目录绝对路径(供生成器 run_command 就地执行 + 读素材)。
    static var directoryPath: String? { directoryURL()?.path }

    /// 生成器脚本绝对路径。
    static var generatorPath: String? {
        guard let dir = directoryURL() else { return nil }
        let url = dir.appendingPathComponent("generator.py")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// 读某个 JSON 资源(palettes/typography/layouts)解析成字典,供 Swift 侧(如 dreaming 进化)读取。
    static func loadJSON(_ name: String) -> [String: Any]? {
        guard let dir = directoryURL() else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: - 可写 overlay(Phase C:dreaming 把进化出的"设计经验"写这里,热加载,不动随包种子)

    /// 可写 overlay 目录(app-support);dreaming 进化产物落这里,与随包只读种子分离。
    static func writableDirectoryURL() -> URL {
        let dir = LingShuRuntimeEnvironment.homeDirectory
            .appendingPathComponent("Library/Application Support/LingShu/DesignKB", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// dreaming 自固化的"设计经验"(纯文字,从历史设计评分学来)。供 apply_skill 注入 PPT 提示,热加载。
    static func designInsights() -> String? {
        let url = writableDirectoryURL().appendingPathComponent("design-insights.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 写入 dreaming 进化出的设计经验(纯文字;调用方须已 sanitize)。
    static func writeDesignInsights(_ text: String) {
        let url = writableDirectoryURL().appendingPathComponent("design-insights.md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// rubric.md 文本(供验收门按设计质量打分)。
    static func rubricText() -> String? {
        guard let dir = directoryURL() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent("rubric.md"), encoding: .utf8)
    }

    /// 可用版式 id 列表(供提示/校验)。
    static func layoutIDs() -> [String] {
        guard let layouts = loadJSON("layouts.json")?["layouts"] as? [[String: Any]] else { return [] }
        return layouts.compactMap { $0["id"] as? String }
    }

    /// 可用配色 id 列表。
    static func paletteIDs() -> [String] {
        guard let palettes = loadJSON("palettes.json")?["palettes"] as? [[String: Any]] else { return [] }
        return palettes.compactMap { $0["id"] as? String }
    }
}
