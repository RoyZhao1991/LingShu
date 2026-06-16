import Foundation

/// 增量记忆持久化(用户要求 Phase 5,参考 MySQL 的 redo log + checkpoint):
/// - **写路径**:每次变更只**追加一行 JSON 到 .wal**(append-only,快——不重写整文件);
/// - **压缩(checkpoint)**:WAL 累计到阈值(或外部定时调 `compact()`)→ 把当前全量写成 `.snapshot`、清空 WAL;
/// - **读路径(跨 app 重启恢复)**:加载 snapshot,再按序回放 WAL 叠加。
///
/// 泛型按「键控记录」组织(upsert/delete),既可存最近产出物,也可扩展存别的记忆。actor 保证并发安全。
actor LingShuIncrementalStore<Record: Codable & Sendable & Identifiable> where Record.ID: Codable & Hashable & Sendable {
    private let snapshotURL: URL
    private let walURL: URL
    private let compactThreshold: Int
    private var records: [Record.ID: Record] = [:]
    private var order: [Record.ID] = []
    private var walCount = 0

    struct WALEntry: Codable {
        enum Op: String, Codable { case upsert, delete }
        let op: Op
        let record: Record?
        let id: Record.ID?
    }

    init(directory: URL, name: String, compactThreshold: Int = 64) {
        self.snapshotURL = directory.appendingPathComponent("\(name).snapshot.json")
        self.walURL = directory.appendingPathComponent("\(name).wal.jsonl")
        self.compactThreshold = max(8, compactThreshold)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 跨重启恢复:加载 snapshot,再回放 WAL 叠加(直接初始化属性,init 内可安全 mutate)。
        if let data = try? Data(contentsOf: snapshotURL),
           let snap = try? JSONDecoder().decode([Record].self, from: data) {
            for r in snap {
                if records[r.id] == nil { order.append(r.id) }
                records[r.id] = r
            }
        }
        if let walText = try? String(contentsOf: walURL, encoding: .utf8) {
            for line in walText.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(WALEntry.self, from: d) else { continue }
                walCount += 1
                switch entry.op {
                case .upsert:
                    if let r = entry.record {
                        if records[r.id] == nil { order.append(r.id) }
                        records[r.id] = r
                    }
                case .delete:
                    if let id = entry.id { records[id] = nil; order.removeAll { $0 == id } }
                }
            }
        }
    }

    /// 当前全量(按插入序)。
    func all() -> [Record] { order.compactMap { records[$0] } }

    /// 追加/更新一条(增量写 WAL,够阈值自动 checkpoint)。
    func upsert(_ record: Record) {
        if records[record.id] == nil { order.append(record.id) }
        records[record.id] = record
        appendWAL(.init(op: .upsert, record: record, id: record.id))
    }

    func delete(_ id: Record.ID) {
        guard records[id] != nil else { return }
        records[id] = nil
        order.removeAll { $0 == id }
        appendWAL(.init(op: .delete, record: nil, id: id))
    }

    /// checkpoint:写全量 snapshot + 清空 WAL(把碎片化的增量日志压实)。可被定时器外部调用。
    func compact() {
        let snapshot = all()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: snapshotURL, options: .atomic) }
        try? FileManager.default.removeItem(at: walURL)
        walCount = 0
    }

    // MARK: - 内部

    private func appendWAL(_ entry: WALEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        var line = data
        line.append(0x0A)   // 换行,JSONL
        if let handle = try? FileHandle(forWritingTo: walURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: walURL, options: .atomic)
        }
        walCount += 1
        if walCount >= compactThreshold { compact() }
    }
}
