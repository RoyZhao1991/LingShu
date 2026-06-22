import XCTest
@testable import LingShuMac

/// 本机知识索引(第一刀)守卫:分块器 + 文件索引(检索/删除/增量/持久化)+ 遍历索引器(过滤/增量/删除)。
/// 检索断言走**关键词兜底**(不依赖 NLEmbedding 在 CI 是否可用),保证确定性。
final class LocalKnowledgeTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: 分块器

    func testChunkerShortTextSingleChunk() {
        XCTAssertEqual(LingShuTextChunker.chunk("短文本"), ["短文本"])
        XCTAssertTrue(LingShuTextChunker.chunk("   \n  ").isEmpty)
    }

    func testChunkerLongTextSplitsWithCoverage() {
        let text = String(repeating: "这是一段需要被切分的中文内容。", count: 200)   // 远超 maxChars
        let chunks = LingShuTextChunker.chunk(text, maxChars: 300, overlap: 50)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 360, "块不应远超上限(含断点松弛)") }
        // 覆盖:拼起来应包含原文的代表性片段(去重叠后仍覆盖全程)。
        let joined = chunks.joined()
        XCTAssertTrue(joined.contains("需要被切分"))
    }

    // MARK: 文件索引:检索 / 删除 / 持久化

    func testIndexUpsertAndKeywordSearch() {
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        index.upsertFile(path: "/x/apple.md", mtime: 1, text: "关于 banana 香蕉的笔记,讲了很多水果。")
        index.upsertFile(path: "/x/car.md", mtime: 1, text: "关于 engine 引擎与变速箱的机械笔记。")
        let hits = index.search(query: "banana", limit: 5)
        XCTAssertEqual(hits.first?.path, "/x/apple.md", "含 banana 的文件应排第一:\(hits)")
        XCTAssertEqual(index.indexedFileCount, 2)
    }

    func testExactMatchRanksTopAmongNoise() {
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        // 50 个噪声文件(含常见 token "7001")+ 1 个含唯一整串的目标。
        for i in 0..<50 { index.upsertFile(path: "/n/\(i).md", mtime: 1, text: "无关内容 端口7001 配置项 \(i)") }
        index.upsertFile(path: "/n/target.md", mtime: 1, text: "项目代号 UNIQUETOKEN-7001 负责人赵阳")
        let hits = index.search(query: "UNIQUETOKEN-7001", limit: 6)
        XCTAssertEqual(hits.first?.path, "/n/target.md", "整串精确匹配应排第一,不被向量噪声/常见词淹没")
    }

    func testIndexRemoveFile() {
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        index.upsertFile(path: "/x/a.md", mtime: 1, text: "alpha 内容")
        index.removeFile(path: "/x/a.md")
        XCTAssertEqual(index.indexedFileCount, 0)
        XCTAssertTrue(index.search(query: "alpha", limit: 5).isEmpty)
    }

    func testIndexUpsertReplacesOldChunks() {
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        index.upsertFile(path: "/x/a.md", mtime: 1, text: "uniqueoldtoken 旧内容")
        index.upsertFile(path: "/x/a.md", mtime: 2, text: "uniquenewtoken 新内容")
        // 旧块的**内容**应被替换:任何命中片段都不再含旧 token(向量语义可能仍把 path 召回,但 snippet 必是新内容)。
        XCTAssertFalse(index.search(query: "uniqueoldtoken", limit: 5).contains { $0.snippet.contains("uniqueoldtoken") }, "旧内容应被替换")
        XCTAssertEqual(index.search(query: "uniquenewtoken", limit: 5).first?.path, "/x/a.md")
        XCTAssertEqual(index.knownMtime(for: "/x/a.md"), 2)
        XCTAssertEqual(index.chunkCount, 1, "同文件重索引不应累积块")
    }

    func testIndexRemoveUnderPrefix() {
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        index.upsertFile(path: "/docs/a.md", mtime: 1, text: "aaa")
        index.upsertFile(path: "/code/b.md", mtime: 1, text: "bbb")
        index.removeUnder(prefix: "/docs")
        XCTAssertNil(index.knownMtime(for: "/docs/a.md"))
        XCTAssertNotNil(index.knownMtime(for: "/code/b.md"))
    }

    func testIndexPersistenceRoundTrip() {
        let dir = tempDir()
        do {
            let index = LingShuFileKnowledgeIndex(directory: dir)
            index.upsertFile(path: "/x/persist.md", mtime: 7, text: "persisttoken 持久化内容")
        }
        // 新实例从同目录加载,应保留。
        let reopened = LingShuFileKnowledgeIndex(directory: dir)
        XCTAssertEqual(reopened.knownMtime(for: "/x/persist.md"), 7)
        XCTAssertEqual(reopened.search(query: "persisttoken", limit: 5).first?.path, "/x/persist.md")
    }

    func testKeywordsTokenize() {
        XCTAssertEqual(LingShuFileKnowledgeIndex.keywords("hello 世界 ab"), ["hello", "世", "界", "ab"])
        XCTAssertFalse(LingShuFileKnowledgeIndex.keywords("a 1").contains("a"))   // 单字符英文/数字丢弃
    }

    // MARK: 遍历索引器:过滤 / 增量 / 删除

    private func write(_ dir: URL, _ name: String, _ content: String, mtime: Date? = nil) {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        if let mtime { try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
    }

    func testIndexerFiltersAndIndexes() {
        let root = tempDir()
        write(root, "doc.md", "banana 文档内容")
        write(root, "code.swift", "func hello() {}")
        write(root, "data.bin", "二进制不收")                      // 非文本扩展名
        write(root, "node_modules/lib.md", "应跳过的依赖")          // 噪声目录
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        let stats = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertEqual(stats.indexed, 2, "只应索引 doc.md + code.swift")
        XCTAssertEqual(index.indexedFileCount, 2)
        XCTAssertTrue(index.search(query: "banana", limit: 5).first?.path.hasSuffix("doc.md") ?? false)
        XCTAssertTrue(index.knownMtime(for: root.appendingPathComponent("node_modules/lib.md").path) == nil)
    }

    func testIndexerIncrementalSkipUnchanged() {
        let root = tempDir()
        write(root, "a.md", "alpha", mtime: Date(timeIntervalSince1970: 1000))
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        let first = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertEqual(first.indexed, 1)
        let second = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertEqual(second.indexed, 0, "mtime 未变应跳过")
        XCTAssertGreaterThanOrEqual(second.skipped, 1)
    }

    func testIndexerPicksUpChangesAndDeletions() {
        let root = tempDir()
        write(root, "a.md", "alpha", mtime: Date(timeIntervalSince1970: 1000))
        write(root, "b.md", "beta", mtime: Date(timeIntervalSince1970: 1000))
        let index = LingShuFileKnowledgeIndex(directory: tempDir())
        _ = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertEqual(index.indexedFileCount, 2)

        // 改 a.md(新 mtime)→ 应重索引;删 b.md → 应从索引移除。
        write(root, "a.md", "alpha changed", mtime: Date(timeIntervalSince1970: 2000))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("b.md"))
        let stats = LingShuFileKnowledgeIndexer.reindex(folders: [root.path], into: index)
        XCTAssertEqual(stats.indexed, 1, "a.md 改了应重索引")
        XCTAssertEqual(stats.removed, 1, "b.md 删了应移除")
        XCTAssertEqual(index.indexedFileCount, 1)
        XCTAssertTrue(index.search(query: "changed", limit: 5).first?.path.hasSuffix("a.md") ?? false)
    }
}
