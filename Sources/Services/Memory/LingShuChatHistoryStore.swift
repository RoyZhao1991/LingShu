import Foundation

struct LingShuChatHistoryPage: Equatable {
    var messages: [ChatMessage]
    var hasMoreColdHistory: Bool
}

/// 聊天历史的热/冷分层存储。
///
/// 所有磁盘读写都串行化在 `ioQueue` 上：`save` 异步入队，调用方不阻塞；
/// `load*` 同步穿过同一队列，保证读后写一致。冷历史在内存中缓存，
/// 避免每次保存都重新读盘解码。
final class LingShuChatHistoryStore: @unchecked Sendable {
    private let storageDirectory: URL
    private let hotFileName: String
    private let coldFileName: String
    private let hotRetention: TimeInterval
    private let hotLimit: Int
    private let coldLimit: Int
    private let ioQueue = DispatchQueue(label: "lingshu.chat-history.io", qos: .utility)
    private var cachedColdMessages: [ChatMessage]?

    init(
        storageDirectory: URL = LingShuChatHistoryStore.defaultStorageDirectory(),
        hotFileName: String = "chat-hot.json",
        coldFileName: String = "chat-cold.json",
        hotRetention: TimeInterval = 3 * 24 * 60 * 60,
        hotLimit: Int = 600,
        coldLimit: Int = 5000
    ) {
        self.storageDirectory = storageDirectory
        self.hotFileName = hotFileName
        self.coldFileName = coldFileName
        self.hotRetention = hotRetention
        self.hotLimit = hotLimit
        self.coldLimit = coldLimit
    }

    var hotHistoryFileURL: URL {
        storageDirectory.appendingPathComponent(hotFileName)
    }

    var coldHistoryFileURL: URL {
        storageDirectory.appendingPathComponent(coldFileName)
    }

    static func defaultStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LingShu/History", isDirectory: true)
    }

    func loadInitialHistory(now: Date = Date()) -> LingShuChatHistoryPage {
        ioQueue.sync {
            let cutoff = now.addingTimeInterval(-hotRetention)
            migrateExpiredHotMessages(cutoff: cutoff)

            let hotMessages = loadMessages(from: hotHistoryFileURL)
                .filter { !$0.isLoading && $0.createdAt >= cutoff }
                .sorted { $0.createdAt < $1.createdAt }
                .suffix(hotLimit)
            let coldMessages = loadColdMessagesCached()

            return LingShuChatHistoryPage(
                messages: Array(hotMessages),
                hasMoreColdHistory: !coldMessages.isEmpty
            )
        }
    }

    func loadColdHistory(before oldestMessage: ChatMessage?, existingIDs: Set<UUID>, limit: Int = 48) -> LingShuChatHistoryPage {
        ioQueue.sync {
            let boundary = oldestMessage?.createdAt ?? Date()
            let coldMessages = loadColdMessagesCached()
                .filter { !$0.isLoading && $0.createdAt < boundary && !existingIDs.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }

            let page = Array(coldMessages.prefix(limit))
                .sorted { $0.createdAt < $1.createdAt }

            return LingShuChatHistoryPage(
                messages: page,
                hasMoreColdHistory: coldMessages.count > page.count
            )
        }
    }

    /// 异步保存：仅在调用线程做一次数组快照拷贝，合并、编码与写盘全部在后台串行队列完成。
    func save(_ messages: [ChatMessage], now: Date = Date()) {
        ioQueue.async {
            self.performSave(messages, now: now)
        }
    }

    /// 同步落盘队列中所有待写任务。退出前调用，确保不丢最后一段对话。
    func flush() {
        ioQueue.sync {}
    }

    private func performSave(_ messages: [ChatMessage], now: Date) {
        let cutoff = now.addingTimeInterval(-hotRetention)
        let visibleMessages = messages
            .filter { !$0.isLoading }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let existingCold = loadColdMessagesCached()
        let merged = unique(visibleMessages + existingCold)
        let hot = Array(merged
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(hotLimit))
            .sorted { $0.createdAt < $1.createdAt }
        let hotIDs = Set(hot.map(\.id))
        let cold = Array(merged
            .filter { $0.createdAt < cutoff && !hotIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(coldLimit))
            .sorted { $0.createdAt < $1.createdAt }

        save(hot, to: hotHistoryFileURL)
        save(cold, to: coldHistoryFileURL)
        cachedColdMessages = cold
    }

    private func migrateExpiredHotMessages(cutoff: Date) {
        let hot = loadMessages(from: hotHistoryFileURL)
        let retainedHot = hot.filter { $0.createdAt >= cutoff }
        let expiredHot = hot.filter { $0.createdAt < cutoff }
        guard retainedHot.count != hot.count else { return }

        let cold = Array(unique(expiredHot + loadColdMessagesCached())
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(coldLimit))
            .sorted { $0.createdAt < $1.createdAt }

        save(retainedHot.sorted { $0.createdAt < $1.createdAt }, to: hotHistoryFileURL)
        save(cold, to: coldHistoryFileURL)
        cachedColdMessages = cold
    }

    /// 仅允许在 ioQueue 上调用。
    private func loadColdMessagesCached() -> [ChatMessage] {
        if let cachedColdMessages {
            return cachedColdMessages
        }
        let cold = loadMessages(from: coldHistoryFileURL)
        cachedColdMessages = cold
        return cold
    }

    private func loadMessages(from url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return decoded
    }

    private func save(_ messages: [ChatMessage], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            try data.write(to: url, options: [.atomic])
        } catch {
            assertionFailure("Failed to save LingShu chat history: \(error.localizedDescription)")
        }
    }

    private func unique(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seen = Set<UUID>()
        return messages.filter { message in
            seen.insert(message.id).inserted
        }
    }
}
