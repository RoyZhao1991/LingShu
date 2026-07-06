import Foundation

enum LingShuHistorySearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case hot
    case cold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .hot: return "热记录"
        case .cold: return "冷备"
        }
    }

    fileprivate var includesHot: Bool { self == .all || self == .hot }
    fileprivate var includesCold: Bool { self == .all || self == .cold }
}

enum LingShuHistorySearchSource: String, Sendable {
    case hotChat
    case coldChat
    case hotTask
    case coldTask

    var label: String {
        switch self {
        case .hotChat: return "热对话"
        case .coldChat: return "冷备对话"
        case .hotTask: return "热任务"
        case .coldTask: return "冷备任务"
        }
    }

    var isTask: Bool {
        switch self {
        case .hotTask, .coldTask: return true
        case .hotChat, .coldChat: return false
        }
    }
}

struct LingShuHistorySearchHit: Identifiable, Equatable, Sendable {
    var id: String
    var source: LingShuHistorySearchSource
    var title: String
    var snippet: String
    var timestamp: Date
    var recordID: String?
    var messageID: String?
    var score: Int
}

enum LingShuConversationHistorySearch {
    static func search(
        keyword rawKeyword: String,
        scope: LingShuHistorySearchScope,
        hotChat: [ChatMessage],
        coldChat: [ChatMessage],
        hotTaskRecords: [LingShuTaskExecutionRecord],
        coldTaskRecords: [LingShuTaskExecutionRecord],
        limit: Int = 80
    ) -> [LingShuHistorySearchHit] {
        let terms = searchTerms(from: rawKeyword)
        guard !terms.isEmpty else { return [] }

        var hits: [LingShuHistorySearchHit] = []

        if scope.includesHot {
            hits += chatHits(messages: hotChat, source: .hotChat, terms: terms)
            hits += taskHits(records: hotTaskRecords, source: .hotTask, terms: terms)
        }

        if scope.includesCold {
            let hotChatIDs = Set(hotChat.map(\.id))
            let hotTaskIDs = Set(hotTaskRecords.map(\.id))
            hits += chatHits(
                messages: coldChat.filter { !hotChatIDs.contains($0.id) },
                source: .coldChat,
                terms: terms
            )
            hits += taskHits(
                records: coldTaskRecords.filter { !hotTaskIDs.contains($0.id) },
                source: .coldTask,
                terms: terms
            )
        }

        return hits
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.timestamp > $1.timestamp
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    private static func chatHits(
        messages: [ChatMessage],
        source: LingShuHistorySearchSource,
        terms: [String]
    ) -> [LingShuHistorySearchHit] {
        messages.compactMap { message in
            let title = message.isUser ? "你" : message.speaker
            let searchable = [title, message.text, message.attachmentNames?.joined(separator: " ") ?? ""].joined(separator: "\n")
            guard let score = matchScore(searchable, terms: terms) else { return nil }
            return LingShuHistorySearchHit(
                id: "\(source.rawValue)-\(message.id.uuidString)",
                source: source,
                title: title,
                snippet: snippet(from: message.text, terms: terms),
                timestamp: message.createdAt,
                recordID: message.taskRecordID,
                messageID: message.id.uuidString,
                score: score
            )
        }
    }

    private static func taskHits(
        records: [LingShuTaskExecutionRecord],
        source: LingShuHistorySearchSource,
        terms: [String]
    ) -> [LingShuHistorySearchHit] {
        records.compactMap { record in
            let artifactText = record.artifacts
                .map { "\($0.title)\n\($0.location)\n\($0.producer)" }
                .joined(separator: "\n")
            let messageText = record.messages
                .map { "\($0.actor)\n\($0.role)\n\($0.text)" }
                .joined(separator: "\n")
            let searchable = [
                record.title,
                record.goal,
                record.prompt,
                record.summary,
                record.participants.joined(separator: " "),
                artifactText,
                messageText
            ].joined(separator: "\n")
            guard let score = matchScore(searchable, terms: terms) else { return nil }
            let snippetBase = [record.summary, record.prompt, messageText, artifactText]
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? record.title
            return LingShuHistorySearchHit(
                id: "\(source.rawValue)-\(record.id)",
                source: source,
                title: record.title.isEmpty ? "未命名任务" : record.title,
                snippet: snippet(from: snippetBase, terms: terms),
                timestamp: record.updatedAt,
                recordID: record.id,
                messageID: nil,
                score: score + 4
            )
        }
    }

    private static func searchTerms(from rawKeyword: String) -> [String] {
        let normalized = normalize(rawKeyword)
        guard !normalized.isEmpty else { return [] }
        let split = normalized
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if split.isEmpty { return [normalized] }
        return Array(Set(split + [normalized])).sorted { $0.count > $1.count }
    }

    private static func matchScore(_ text: String, terms: [String]) -> Int? {
        let normalized = normalize(text)
        guard terms.allSatisfy({ normalized.contains($0) }) else { return nil }
        return terms.reduce(0) { partial, term in
            partial + normalized.components(separatedBy: term).count - 1 + min(term.count, 16)
        }
    }

    private static func snippet(from text: String, terms: [String], limit: Int = 150) -> String {
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let preferred = cleaned.first { line in
            let normalizedLine = normalize(line)
            return terms.contains { normalizedLine.contains($0) }
        } ?? cleaned.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard preferred.count > limit else { return preferred }
        return "\(preferred.prefix(limit))..."
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
