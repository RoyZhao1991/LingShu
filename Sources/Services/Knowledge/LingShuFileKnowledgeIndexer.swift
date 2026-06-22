import Foundation

/// 本机知识索引·**文件遍历索引器**:走 opt-in 目录,把文本/文档/代码文件喂进 `LingShuFileKnowledgeIndex`。
///
/// 增量:按文件 mtime 跳过未变;索引目录里已消失的文件从索引删除。只收文本类扩展名 + 限大小(跳二进制/超大)。
/// 全本地、零上传。可单测(给临时目录跑、断言增量行为)。
enum LingShuFileKnowledgeIndexer {
    /// 收录的文本类扩展名(文档/代码/配置/纯文本)。二进制/媒体不收(第一刀只做"能直接读成文本"的)。
    static let textExtensions: Set<String> = Set([
        "md", "markdown", "txt", "text", "rtf", "tex", "org", "rst",
        "swift", "py", "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "cc", "m", "mm",
        "java", "kt", "go", "rs", "rb", "php", "cs", "scala", "sh", "zsh", "bash", "pl", "lua", "r",
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "csv", "tsv", "sql",
        "html", "htm", "css", "scss", "vue", "svelte", "gradle", "properties", "env", "log"
    ]).union(LingShuDocumentText.documentExtensions)   // + PDF 等文档(多源 ①)
    static let maxFileBytes = 1_000_000          // 跳过 >1MB 的文件(超大日志/数据)
    /// 跳过的目录名(噪声/体积/不该索引)。
    static let skipDirNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "DerivedData", ".venv", "venv",
        "__pycache__", ".cache", "Pods", ".next", "target", ".idea", ".swiftpm", "vendor"
    ]

    struct Stats: Equatable { var indexed = 0; var skipped = 0; var removed = 0; var scanned = 0 }

    /// 文件源**归属**(给统一增量管线剪枝用):非图片的绝对文件路径(图片归照片源,见 LingShuKnowledgeIngest.isImagePath)。
    static func owns(_ path: String) -> Bool { path.hasPrefix("/") && !LingShuKnowledgeIngest.isImagePath(path) }

    /// 扫描 opt-in 目录 → 归一成 `LingShuKnowledgeScan`(增量:用 `knownMtime` 跳过未变,不重复抽取)。供统一管线入库。
    static func scan(folders: [String], knownMtime: (String) -> Double?, fileManager: FileManager = .default) -> LingShuKnowledgeScan {
        var scanned = LingShuKnowledgeScan()
        // 解析符号链接(/var→/private/var),与 fileExists/索引内路径口径一致。
        let roots = folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().path }
        for root in roots {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let en = fileManager.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                if url.hasDirectoryPath {
                    if skipDirNames.contains(url.lastPathComponent) { en.skipDescendants() }
                    continue
                }
                guard textExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard (v?.isRegularFile ?? false) else { continue }
                if let size = v?.fileSize, size > maxFileBytes { continue }
                let path = url.path
                scanned.seenPaths.insert(path)
                let mtime = (v?.contentModificationDate ?? .distantPast).timeIntervalSince1970
                if knownMtime(path) == mtime { continue }   // 增量:未变不重抽
                guard let text = LingShuDocumentText.extract(from: url), !text.isEmpty else { continue }
                scanned.changed.append(.init(path: path, mtime: mtime, text: text))
            }
        }
        return scanned
    }

    /// 增量重索引若干 opt-in 目录(= 扫描 + 统一管线入库)。返回统计。
    @discardableResult
    static func reindex(folders: [String], into index: LingShuFileKnowledgeIndex,
                        fileManager: FileManager = .default) -> Stats {
        let scanned = scan(folders: folders, knownMtime: { index.knownMtime(for: $0) }, fileManager: fileManager)
        let r = LingShuKnowledgeIngest.ingest(scanned, owns: owns,
                                              stillExists: { fileManager.fileExists(atPath: $0) }, into: index)
        return Stats(indexed: r.indexed, skipped: max(0, r.seen - r.indexed), removed: r.removed, scanned: r.seen)
    }
}
