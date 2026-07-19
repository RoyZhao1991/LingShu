import Foundation

/// 资源自获取的本地注册表("任何东西都一样":模板/图标/字体/参考都先查这里)。
/// 资源落 `~/Library/Application Support/LingShu/Resources/<kind>/`,清单 `resources.json`。
/// 命中即复用(不重复联网下载);未命中由 `acquire_resource` 联网取回后 `register` 入库。
struct LingShuResourceEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String { localPath }
    var kind: String        // pptx-template / icon-set / font / reference …
    var name: String
    var tags: [String]
    var localPath: String
    var source: String      // 来源 URL(或 "bundled")
    var license: String
    var addedAt: Date
}

final class LingShuResourceRegistry: @unchecked Sendable {
    static let shared = LingShuResourceRegistry()

    private let baseDir: URL
    private let manifestURL: URL
    private let lock = NSLock()
    private var entries: [LingShuResourceEntry]

    init(baseDir: URL? = nil) {
        let dir = baseDir ?? LingShuRuntimeEnvironment.homeDirectory
            .appendingPathComponent("Library/Application Support/LingShu/Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.baseDir = dir
        self.manifestURL = dir.appendingPathComponent("resources.json")
        self.entries = Self.loadManifest(manifestURL)
    }

    /// 某类资源的存储目录(自动建)。
    func resourceDir(forKind kind: String) -> URL {
        let dir = baseDir.appendingPathComponent(kind, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 查本地:同 kind 的条目按"与 query 的词重合度"排序返回(含 0 分兜底——同类任何资源也比没有强)。
    /// 只返回文件仍在盘上的条目。
    func lookup(kind: String, query: String, limit: Int = 5) -> [LingShuResourceEntry] {
        lock.lock(); let all = entries; lock.unlock()
        let q = query.lowercased()
        let tokens = q.split(whereSeparator: { " ,，、/".contains($0) }).map(String.init).filter { !$0.isEmpty }
        return all
            .filter { $0.kind == kind && FileManager.default.fileExists(atPath: $0.localPath) }
            .map { entry -> (LingShuResourceEntry, Int) in
                let hay = (entry.name + " " + entry.tags.joined(separator: " ")).lowercased()
                let score = tokens.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) } + (q.isEmpty || hay.contains(q) ? 1 : 0)
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// 登记一条资源(按 localPath 去重覆盖)。
    func register(kind: String, name: String, tags: [String], localPath: String, source: String, license: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.localPath == localPath }
        entries.append(.init(kind: kind, name: name, tags: tags, localPath: localPath, source: source, license: license, addedAt: Date()))
        persist()
    }

    func all() -> [LingShuResourceEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    var count: Int { all().count }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries.sorted { $0.addedAt > $1.addedAt }) else { return }
        try? data.write(to: manifestURL, options: [.atomic])
    }

    private static func loadManifest(_ url: URL) -> [LingShuResourceEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LingShuResourceEntry].self, from: data) else { return [] }
        return decoded
    }

    /// 各类资源允许的扩展名(只收数据/素材,拒可执行)。
    static func allowedExtensions(forKind kind: String) -> [String] {
        switch kind {
        case "pptx-template": return ["pptx", "potx"]
        case "icon-set":      return ["svg", "png", "zip"]
        case "font":          return ["ttf", "otf", "woff", "woff2"]
        case "reference":     return ["md", "txt", "pdf"]
        default:               return ["pptx", "potx", "svg", "png", "ttf", "otf", "md", "txt", "pdf", "json", "csv"]
        }
    }

    /// 联网检索词:给 kind 加合适的修饰,提高命中可下载的开源资源。
    static func onlineQuery(kind: String, query: String) -> String {
        switch kind {
        case "pptx-template": return "\(query) powerpoint pptx template free download"
        case "icon-set":      return "\(query) svg icons open source github"
        case "font":          return "\(query) open font ttf download"
        case "reference":     return "\(query) reference document"
        default:               return query
        }
    }

    // MARK: - 内置开源兜底直链(联网搜索被限流 / 无直链时用)

    /// 一条经核实的开源资源直链(GitHub raw 等):许可明确、可直接下载、魔数对得上。
    struct CuratedSource: Sendable, Equatable {
        let url: String
        let name: String
        let license: String
        let tags: [String]
    }

    /// 内置一小套**已核实开源许可**的资源直链兜底——`acquire_resource` 联网搜不到/拿不到直链时用。
    /// 现实:模板站多是 JS 页面/非直链、DuckDuckGo HTML 常被限流(实测返回 202);只有 GitHub raw 这类
    /// 稳定可下。这里只放许可明确(MIT/CC0/Apache…)、实测可下且魔数校验通过的源。
    /// 注:这是**兜底地板**(保证至少有个可用主题底),不是"找最美模板"——后者仍走 web_search/用户自带品牌模板。
    static func curatedFallbackSources(forKind kind: String) -> [CuratedSource] {
        switch kind {
        case "pptx-template":
            // python-pptx 自带的标准模板(MIT)。携带经典 Office 浅色主题(蓝 #4F81BD / Calibri),
            // 经 generator 模板主题提取后,可把深色默认观感切成干净的浅色商务风(与内置 6 套配色互补)。
            return [
                .init(url: "https://raw.githubusercontent.com/scanny/python-pptx/master/src/pptx/templates/default.pptx",
                      name: "office-neutral",
                      license: "MIT (python-pptx)",
                      tags: ["business", "report", "neutral", "office", "light"])
            ]
        default:
            return []
        }
    }
}
