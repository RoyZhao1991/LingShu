import Foundation

/// 知识库的磁盘载体(vault):每条 note 一个 `.md` 文件,按 kind 分子目录;归档进 `archive/`。
/// 真相源就是这些文件——人可用任意编辑器(含 Obsidian)打开、手改、grep、diff。纯 IO,无业务逻辑。
struct LingShuMemoryVault {
    let root: URL
    private var archiveDir: URL { root.appendingPathComponent("archive", isDirectory: true) }
    private let fm = FileManager.default

    init(root: URL) { self.root = root }

    /// 建好根目录与各 kind 子目录 + archive。
    func ensureDirectories() {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        for kind in LingShuMemoryNote.Kind.allCases {
            try? fm.createDirectory(at: root.appendingPathComponent(kind.rawValue, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    private func fileURL(_ note: LingShuMemoryNote) -> URL {
        root.appendingPathComponent(note.kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(note.id).md")
    }

    func save(_ note: LingShuMemoryNote) throws {
        let url = fileURL(note)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.markdown().data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// 加载全部活跃 note(不含 archive)。坏文件跳过,不崩。
    func loadAll() -> [LingShuMemoryNote] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var notes: [LingShuMemoryNote] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            if url.path.contains("/archive/") { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let note = LingShuMemoryNote.parse(text) {
                notes.append(note)
            }
        }
        return notes
    }

    /// 归档:写到 archive/ 并删掉活跃文件(不真删,可还原)。
    func archive(_ note: LingShuMemoryNote) throws {
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let dst = archiveDir.appendingPathComponent("\(note.id).md")
        try note.markdown().data(using: .utf8)?.write(to: dst, options: .atomic)
        try? fm.removeItem(at: fileURL(note))
    }

    func delete(_ note: LingShuMemoryNote) {
        try? fm.removeItem(at: fileURL(note))
    }
}
