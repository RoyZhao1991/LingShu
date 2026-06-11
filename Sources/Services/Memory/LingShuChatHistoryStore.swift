import Foundation

struct LingShuChatHistoryPage: Equatable {
    var messages: [ChatMessage]
    var hasMoreColdHistory: Bool
}

final class LingShuChatHistoryStore {
    private let storageDirectory: URL
    private let hotFileName: String
    private let coldFileName: String
    private let hotRetention: TimeInterval
    private let hotLimit: Int
    private let coldLimit: Int

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
        let cutoff = now.addingTimeInterval(-hotRetention)
        migrateExpiredHotMessages(cutoff: cutoff)

        let hotMessages = loadMessages(from: hotHistoryFileURL)
            .filter { !$0.isLoading && $0.createdAt >= cutoff }
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(hotLimit)
        let coldMessages = loadMessages(from: coldHistoryFileURL)

        return LingShuChatHistoryPage(
            messages: Array(hotMessages),
            hasMoreColdHistory: !coldMessages.isEmpty
        )
    }

    func loadColdHistory(before oldestMessage: ChatMessage?, existingIDs: Set<UUID>, limit: Int = 48) -> LingShuChatHistoryPage {
        let boundary = oldestMessage?.createdAt ?? Date()
        let coldMessages = loadMessages(from: coldHistoryFileURL)
            .filter { !$0.isLoading && $0.createdAt < boundary && !existingIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }

        let page = Array(coldMessages.prefix(limit))
            .sorted { $0.createdAt < $1.createdAt }

        return LingShuChatHistoryPage(
            messages: page,
            hasMoreColdHistory: coldMessages.count > page.count
        )
    }

    func save(_ messages: [ChatMessage], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-hotRetention)
        let visibleMessages = messages
            .filter { !$0.isLoading }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let existingCold = loadMessages(from: coldHistoryFileURL)
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
    }

    private func migrateExpiredHotMessages(cutoff: Date) {
        let hot = loadMessages(from: hotHistoryFileURL)
        let retainedHot = hot.filter { $0.createdAt >= cutoff }
        let expiredHot = hot.filter { $0.createdAt < cutoff }
        guard retainedHot.count != hot.count else { return }

        let cold = Array(unique(expiredHot + loadMessages(from: coldHistoryFileURL))
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(coldLimit))
            .sorted { $0.createdAt < $1.createdAt }

        save(retainedHot.sorted { $0.createdAt < $1.createdAt }, to: hotHistoryFileURL)
        save(cold, to: coldHistoryFileURL)
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
