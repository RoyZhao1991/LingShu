import Foundation

enum LingShuTaskExecutionStatus: String, Codable, Equatable, Sendable {
    case queued = "排队中"
    case running = "执行中"
    case answered = "已直接回答"
    case dispatched = "已分派"
    case completed = "已完成"
    case blocked = "异常"
}

enum LingShuTaskExecutionMessageKind: String, Codable, Equatable, Sendable {
    case user
    case core
    case memory
    case router
    case agent
    case model
    case review
    case result
    case warning
}

struct LingShuTaskExecutionMessage: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var timestamp: Date
    var actor: String
    var role: String
    var kind: LingShuTaskExecutionMessageKind
    var text: String

    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        actor: String,
        role: String,
        kind: LingShuTaskExecutionMessageKind,
        text: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actor = actor
        self.role = role
        self.kind = kind
        self.text = text
    }
}

struct LingShuTaskExecutionArtifact: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var location: String
    var producer: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        location: String,
        producer: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.producer = producer
        self.createdAt = createdAt
    }
}

struct LingShuTaskExecutionRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var prompt: String
    var status: LingShuTaskExecutionStatus
    var summary: String
    var participants: [String]
    var relatedRecordIDs: [String]
    var createdAt: Date
    var updatedAt: Date
    var messages: [LingShuTaskExecutionMessage]
    var artifacts: [LingShuTaskExecutionArtifact]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case prompt
        case status
        case summary
        case participants
        case relatedRecordIDs
        case createdAt
        case updatedAt
        case messages
        case artifacts
    }

    init(
        id: String,
        title: String,
        prompt: String,
        status: LingShuTaskExecutionStatus,
        summary: String,
        participants: [String],
        relatedRecordIDs: [String] = [],
        createdAt: Date,
        updatedAt: Date,
        messages: [LingShuTaskExecutionMessage],
        artifacts: [LingShuTaskExecutionArtifact] = []
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.status = status
        self.summary = summary
        self.participants = participants
        self.relatedRecordIDs = relatedRecordIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.artifacts = artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        status = try container.decode(LingShuTaskExecutionStatus.self, forKey: .status)
        summary = try container.decode(String.self, forKey: .summary)
        participants = try container.decode([String].self, forKey: .participants)
        relatedRecordIDs = try container.decodeIfPresent([String].self, forKey: .relatedRecordIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = try container.decode([LingShuTaskExecutionMessage].self, forKey: .messages)
        artifacts = try container.decodeIfPresent([LingShuTaskExecutionArtifact].self, forKey: .artifacts) ?? []
    }

    static func create(prompt: String, now: Date = Date()) -> LingShuTaskExecutionRecord {
        let title = Self.shortTitle(from: prompt)
        return .init(
            id: "task-record-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
            title: title,
            prompt: prompt,
            status: .running,
            summary: "灵枢正在判断本轮任务。",
            participants: ["你", "灵枢"],
            relatedRecordIDs: [],
            createdAt: now,
            updatedAt: now,
            messages: [
                .init(timestamp: now, actor: "你", role: "需求方", kind: .user, text: prompt),
                .init(timestamp: now, actor: "灵枢", role: "中枢", kind: .core, text: "收到。我先判断这件事由我直接回答，还是需要调度能力节点。")
            ]
        )
    }

    mutating func append(
        actor: String,
        role: String,
        kind: LingShuTaskExecutionMessageKind,
        text: String,
        now: Date = Date()
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if messages.last?.actor == actor,
           messages.last?.kind == kind,
           messages.last?.text == cleaned {
            return
        }

        messages.append(.init(timestamp: now, actor: actor, role: role, kind: kind, text: cleaned))
        if !participants.contains(actor) {
            participants.append(actor)
        }
        if messages.count > 140 {
            messages.removeFirst(messages.count - 140)
        }
        updatedAt = now
    }

    mutating func appendArtifact(
        title: String,
        location: String,
        producer: String,
        now: Date = Date()
    ) {
        let cleanedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedLocation.isEmpty else { return }

        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if artifacts.contains(where: { $0.location == cleanedLocation }) {
            return
        }

        artifacts.append(.init(
            title: cleanedTitle.isEmpty ? "未命名产出物" : cleanedTitle,
            location: cleanedLocation,
            producer: producer,
            createdAt: now
        ))
        updatedAt = now
    }

    mutating func linkRelatedRecord(_ recordID: String, now: Date = Date()) {
        let cleaned = recordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != id, !relatedRecordIDs.contains(cleaned) else { return }
        relatedRecordIDs.append(cleaned)
        updatedAt = now
    }

    mutating func applyRoute(needsAgents: Bool, agents: [String], summary: String, now: Date = Date()) {
        status = needsAgents ? .dispatched : .answered
        self.summary = summary.isEmpty ? (needsAgents ? "本轮已完成能力分派。" : "本轮由灵枢直接回答。") : summary
        participants = Array(Set(participants + agents)).sorted { left, right in
            if left == "你" { return true }
            if right == "你" { return false }
            if left == "灵枢" { return true }
            if right == "灵枢" { return false }
            return left < right
        }
        updatedAt = now
    }

    mutating func finish(status: LingShuTaskExecutionStatus, summary: String, now: Date = Date()) {
        self.status = status
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.summary : summary
        updatedAt = now
    }

    private static func shortTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 24 else { return trimmed.isEmpty ? "未命名任务" : trimmed }
        return "\(trimmed.prefix(24))..."
    }
}

/// 任务执行日志。写入串行化在 `ioQueue` 上异步完成，调用方不等待编码与落盘；
/// 读取同步穿过同一队列，保证读后写一致。归档记录在内存中缓存，
/// 避免每次保存都重新解码全部归档。
final class LingShuTaskExecutionJournal: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let archiveStorageKey: String
    private let maxRecords: Int
    private let maxArchivedRecords: Int
    private let ioQueue = DispatchQueue(label: "lingshu.task-journal.io", qos: .utility)
    private var cachedArchivedRecords: [LingShuTaskExecutionRecord]?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "lingshu.task-execution.records",
        archiveStorageKey: String = "lingshu.task-execution.records.archive",
        maxRecords: Int = 80,
        maxArchivedRecords: Int = 320
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.archiveStorageKey = archiveStorageKey
        self.maxRecords = maxRecords
        self.maxArchivedRecords = maxArchivedRecords
    }

    func loadRecords() -> [LingShuTaskExecutionRecord] {
        ioQueue.sync {
            guard let data = defaults.data(forKey: storageKey),
                  let records = try? JSONDecoder().decode([LingShuTaskExecutionRecord].self, from: data) else {
                return []
            }
            return records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxRecords).map { $0 }
        }
    }

    func loadArchivedRecords() -> [LingShuTaskExecutionRecord] {
        ioQueue.sync {
            loadArchivedRecordsCached()
        }
    }

    /// 归一化并保存记录。返回值即保存后的（活跃, 归档）两组数据，
    /// 调用方应直接采用返回值，而不是保存后再从磁盘读回。
    @discardableResult
    func saveRecords(_ records: [LingShuTaskExecutionRecord]) -> (active: [LingShuTaskExecutionRecord], archived: [LingShuTaskExecutionRecord]) {
        ioQueue.sync {
            let sorted = unique(records).sorted { $0.updatedAt > $1.updatedAt }
            let retained = Array(sorted.prefix(maxRecords))
            let retainedIDs = Set(retained.map(\.id))
            let overflow = sorted.dropFirst(maxRecords)
            let archived = unique(Array(overflow) + loadArchivedRecordsCached())
                .filter { !retainedIDs.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maxArchivedRecords)
                .map { $0 }
            cachedArchivedRecords = archived

            ioQueue.async {
                if let data = try? JSONEncoder().encode(retained) {
                    self.defaults.set(data, forKey: self.storageKey)
                }
                if let archiveData = try? JSONEncoder().encode(archived) {
                    self.defaults.set(archiveData, forKey: self.archiveStorageKey)
                }
            }

            return (retained, archived)
        }
    }

    /// 同步落盘队列中所有待写任务。退出前调用。
    func flush() {
        ioQueue.sync {}
    }

    /// 仅允许在 ioQueue 上调用。
    private func loadArchivedRecordsCached() -> [LingShuTaskExecutionRecord] {
        if let cachedArchivedRecords {
            return cachedArchivedRecords
        }
        guard let data = defaults.data(forKey: archiveStorageKey),
              let records = try? JSONDecoder().decode([LingShuTaskExecutionRecord].self, from: data) else {
            cachedArchivedRecords = []
            return []
        }
        let archived = records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxArchivedRecords).map { $0 }
        cachedArchivedRecords = archived
        return archived
    }

    func upsert(_ record: LingShuTaskExecutionRecord, into records: inout [LingShuTaskExecutionRecord]) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records = unique(records).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func unique(_ records: [LingShuTaskExecutionRecord]) -> [LingShuTaskExecutionRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}
