import XCTest
@testable import LingShuMac

/// 资源自获取注册表(`LingShuResourceRegistry`)纯逻辑单测:
/// 入库/去重/持久化、查询相关性排序、丢失文件过滤、各 kind 的扩展名/检索词/内置兜底源。
/// 用临时 baseDir 注入,完全隔离,不碰真实 ~/Library。
final class ResourceRegistryTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-registry-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 在某目录造一个占位文件,返回其路径(lookup 只返回盘上仍存在的条目,需真实文件)。
    private func touch(_ dir: URL, _ name: String) -> String {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        return path
    }

    func testRegisterLookupRoundTrip() {
        let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let reg = LingShuResourceRegistry(baseDir: base)
        let kindDir = reg.resourceDir(forKind: "pptx-template")
        let p = touch(kindDir, "business.pptx")
        reg.register(kind: "pptx-template", name: "business", tags: ["business", "report"],
                     localPath: p, source: "https://example.com/x.pptx", license: "MIT")
        let hits = reg.lookup(kind: "pptx-template", query: "business")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.localPath, p)
        XCTAssertEqual(hits.first?.name, "business")
        XCTAssertEqual(reg.count, 1)
    }

    func testRegisterDedupesByLocalPath() {
        let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let reg = LingShuResourceRegistry(baseDir: base)
        let p = touch(reg.resourceDir(forKind: "font"), "f.ttf")
        reg.register(kind: "font", name: "old", tags: [], localPath: p, source: "a", license: "OFL")
        reg.register(kind: "font", name: "new", tags: ["sans"], localPath: p, source: "b", license: "OFL")
        XCTAssertEqual(reg.count, 1, "同 localPath 应覆盖而非新增")
        XCTAssertEqual(reg.lookup(kind: "font", query: "sans").first?.name, "new")
    }

    func testLookupRanksByQueryOverlap() {
        let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let reg = LingShuResourceRegistry(baseDir: base)
        let dir = reg.resourceDir(forKind: "pptx-template")
        let tech = touch(dir, "tech.pptx"); let biz = touch(dir, "biz.pptx")
        reg.register(kind: "pptx-template", name: "generic", tags: ["plain"], localPath: biz, source: "a", license: "MIT")
        reg.register(kind: "pptx-template", name: "tech minimal", tags: ["tech", "minimal"], localPath: tech, source: "b", license: "MIT")
        let hits = reg.lookup(kind: "pptx-template", query: "tech minimal")
        XCTAssertEqual(hits.first?.localPath, tech, "词重合度高的条目应排最前")
        XCTAssertEqual(hits.count, 2, "同 kind 任何条目都应返回(0 分兜底,有总比没有强)")
    }

    func testLookupFiltersOutMissingFiles() {
        let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let reg = LingShuResourceRegistry(baseDir: base)
        let dir = reg.resourceDir(forKind: "icon-set")
        let p = touch(dir, "icons.zip")
        reg.register(kind: "icon-set", name: "set", tags: [], localPath: p, source: "a", license: "ISC")
        XCTAssertEqual(reg.lookup(kind: "icon-set", query: "").count, 1)
        try? FileManager.default.removeItem(atPath: p)
        XCTAssertEqual(reg.lookup(kind: "icon-set", query: "").count, 0, "文件被删后 lookup 不应再返回")
    }

    func testManifestPersistsAcrossInstances() {
        let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let p: String
        do {
            let reg = LingShuResourceRegistry(baseDir: base)
            p = touch(reg.resourceDir(forKind: "reference"), "ref.md")
            reg.register(kind: "reference", name: "guide", tags: ["guide"], localPath: p, source: "a", license: "CC0")
        }
        let reg2 = LingShuResourceRegistry(baseDir: base)  // 新实例从 manifest 读
        XCTAssertEqual(reg2.lookup(kind: "reference", query: "guide").first?.localPath, p)
    }

    func testAllowedExtensionsByKind() {
        XCTAssertEqual(LingShuResourceRegistry.allowedExtensions(forKind: "pptx-template"), ["pptx", "potx"])
        XCTAssertTrue(LingShuResourceRegistry.allowedExtensions(forKind: "font").contains("ttf"))
        XCTAssertTrue(LingShuResourceRegistry.allowedExtensions(forKind: "icon-set").contains("svg"))
        // 未知 kind 给宽松集合但仍不含可执行扩展。
        let unknown = LingShuResourceRegistry.allowedExtensions(forKind: "whatever")
        XCTAssertFalse(unknown.contains("sh"))
        XCTAssertFalse(unknown.contains("py"))
        XCTAssertFalse(unknown.contains("exe"))
    }

    func testOnlineQueryDecoratesByKind() {
        XCTAssertTrue(LingShuResourceRegistry.onlineQuery(kind: "pptx-template", query: "business").contains("pptx"))
        XCTAssertTrue(LingShuResourceRegistry.onlineQuery(kind: "icon-set", query: "ui").lowercased().contains("svg"))
        XCTAssertTrue(LingShuResourceRegistry.onlineQuery(kind: "font", query: "serif").lowercased().contains("ttf"))
    }

    func testCuratedFallbackSourcesAreSafeDirectLinks() {
        let ppt = LingShuResourceRegistry.curatedFallbackSources(forKind: "pptx-template")
        XCTAssertFalse(ppt.isEmpty, "pptx-template 应有内置兜底源(联网被限流时的地板)")
        for s in ppt {
            XCTAssertTrue(s.url.hasPrefix("https://"), "兜底源必须 https 直链:\(s.url)")
            XCTAssertFalse(s.license.isEmpty, "兜底源必须标明许可")
            // 兜底文件必须是该 kind 允许的(数据/素材)扩展,绝不引入可执行文件。
            let ext = (s.url as NSString).pathExtension.lowercased()
            XCTAssertTrue(LingShuResourceRegistry.allowedExtensions(forKind: "pptx-template").contains(ext),
                          "兜底源扩展名应在白名单内:\(ext)")
        }
        XCTAssertTrue(LingShuResourceRegistry.curatedFallbackSources(forKind: "whatever").isEmpty,
                      "未配置兜底源的 kind 返回空")
    }
}
