import Foundation

enum LingShuRemoteSessionPurpose: String, Codable, CaseIterable, Equatable {
    case mainRouting = "main-routing"
    case taskExecution = "task-execution"
    case directConversation = "direct-conversation"
    case externalAgent = "external-agent"
}

enum LingShuRemoteContextMode: String, Codable, Equatable {
    case commandResume
    case nativeConversation
    case clientManagedContext
    case stateless
}

struct LingShuRemoteModelAdapterProfile: Equatable {
    var provider: String
    var contextMode: LingShuRemoteContextMode
    var supportsStreaming: Bool
    var supportsNativeContinuation: Bool
    var continuationField: String?
    var notes: String

    static func resolve(provider: String, endpoint: String = "", protocolName: String = "") -> Self {
        let normalized = [provider, endpoint, protocolName]
            .joined(separator: " ")
            .lowercased()

        if normalized.contains("responses") || normalized.contains("/responses") {
            return .init(
                provider: provider,
                contextMode: .nativeConversation,
                supportsStreaming: true,
                supportsNativeContinuation: true,
                continuationField: "previous_response_id",
                notes: "通过响应 id 续接服务端上下文。"
            )
        }

        if normalized.contains("thread") || normalized.contains("conversation") {
            return .init(
                provider: provider,
                contextMode: .nativeConversation,
                supportsStreaming: true,
                supportsNativeContinuation: true,
                continuationField: "conversation_id",
                notes: "通过供应商原生会话 id 续接上下文。"
            )
        }

        if normalized.contains("chat/completions")
            || normalized.contains("openai")
            || normalized.contains("deepseek")
            || normalized.contains("minimax")
            || normalized.contains("doubao")
            || normalized.contains("volc")
            || normalized.contains("anthropic")
            || normalized.contains("claude") {
            return .init(
                provider: provider,
                contextMode: .clientManagedContext,
                supportsStreaming: true,
                supportsNativeContinuation: false,
                continuationField: nil,
                notes: "由灵枢会话池保存压缩上下文，每轮随请求续传。"
            )
        }

        return .init(
            provider: provider,
            contextMode: .clientManagedContext,
            supportsStreaming: true,
            supportsNativeContinuation: false,
            continuationField: nil,
            notes: "默认采用客户端压缩上下文策略。"
        )
    }
}

struct LingShuRemoteSessionKey: Codable, Hashable, Equatable {
    var provider: String
    var model: String
    var purpose: LingShuRemoteSessionPurpose
    var contextKey: String
    var workingDirectory: String
    var permissionBoundary: String

    var stableID: String {
        [
            provider,
            model,
            purpose.rawValue,
            contextKey,
            workingDirectory,
            permissionBoundary
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }
}

struct LingShuRemoteSessionRecord: Codable, Equatable, Identifiable {
    var id: String
    var key: LingShuRemoteSessionKey
    var contextMode: LingShuRemoteContextMode
    var nativeSessionID: String?
    var continuationToken: String?
    var localContextSummary: String
    var createdAt: Date
    var lastUsedAt: Date
    var lastHeartbeatAt: Date
    var expiresAt: Date
    var activeCallCount: Int
    var failureCount: Int
}

struct LingShuRemoteSessionLease: Equatable {
    var recordID: String
    var key: LingShuRemoteSessionKey
    var contextMode: LingShuRemoteContextMode
    var nativeSessionID: String?
    var continuationToken: String?
    var localContextSummary: String
    var isWarm: Bool

    var canResumeNativeSession: Bool {
        switch contextMode {
        case .commandResume, .nativeConversation:
            return nativeSessionID?.isEmpty == false || continuationToken?.isEmpty == false
        case .clientManagedContext, .stateless:
            return false
        }
    }
}

struct LingShuRemoteSessionPoolStats: Equatable {
    var online: Int
    var running: Int
    var standby: Int
    var expired: Int

    var statusText: String {
        "在线 \(online) / 运行 \(running) / 待启动 \(standby)"
    }
}

final class LingShuRemoteSessionPool {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let maxHotSessions: Int
    private let warmTTL: TimeInterval
    private var records: [LingShuRemoteSessionRecord]

    init(
        defaults: UserDefaults = LingShuRuntimeEnvironment.preferences,
        storageKey: String = "lingshu.remote-session.pool.records",
        maxHotSessions: Int = 12,
        warmTTL: TimeInterval = 30 * 60,
        now: Date = Date()
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxHotSessions = maxHotSessions
        self.warmTTL = warmTTL
        self.records = Self.loadRecords(defaults: defaults, key: storageKey)
            .filter { $0.expiresAt > now }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(maxHotSessions)
            .map { $0 }
    }

    func lease(
        provider: String,
        model: String,
        purpose: LingShuRemoteSessionPurpose,
        contextKey: String,
        workingDirectory: String,
        permissionBoundary: String,
        endpoint: String = "",
        protocolName: String = "",
        localContextSummary: String = "",
        now: Date = Date()
    ) -> LingShuRemoteSessionLease {
        let profile = LingShuRemoteModelAdapterProfile.resolve(
            provider: provider,
            endpoint: endpoint,
            protocolName: protocolName
        )
        let key = LingShuRemoteSessionKey(
            provider: provider,
            model: model,
            purpose: purpose,
            contextKey: contextKey,
            workingDirectory: workingDirectory,
            permissionBoundary: permissionBoundary
        )

        lock.lock()
        defer {
            pruneLocked(now: now)
            persistLocked()
            lock.unlock()
        }

        if let index = records.firstIndex(where: { $0.key == key && $0.expiresAt > now }) {
            records[index].lastUsedAt = now
            records[index].lastHeartbeatAt = now
            records[index].expiresAt = now.addingTimeInterval(warmTTL)
            records[index].activeCallCount += 1
            if !localContextSummary.isEmpty {
                records[index].localContextSummary = compact(localContextSummary)
            }

            let record = records[index]
            return .init(
                recordID: record.id,
                key: record.key,
                contextMode: record.contextMode,
                nativeSessionID: record.nativeSessionID,
                continuationToken: record.continuationToken,
                localContextSummary: record.localContextSummary,
                isWarm: record.nativeSessionID != nil || record.continuationToken != nil || !record.localContextSummary.isEmpty
            )
        }

        let record = LingShuRemoteSessionRecord(
            id: "remote-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
            key: key,
            contextMode: profile.contextMode,
            nativeSessionID: nil,
            continuationToken: nil,
            localContextSummary: compact(localContextSummary),
            createdAt: now,
            lastUsedAt: now,
            lastHeartbeatAt: now,
            expiresAt: now.addingTimeInterval(warmTTL),
            activeCallCount: 1,
            failureCount: 0
        )
        records.insert(record, at: 0)

        return .init(
            recordID: record.id,
            key: record.key,
            contextMode: record.contextMode,
            nativeSessionID: nil,
            continuationToken: nil,
            localContextSummary: record.localContextSummary,
            isWarm: false
        )
    }

    func resolveNativeSession(
        lease: LingShuRemoteSessionLease,
        nativeSessionID: String?,
        continuationToken: String? = nil,
        localContextSummary: String = "",
        now: Date = Date()
    ) {
        lock.lock()
        defer {
            pruneLocked(now: now)
            persistLocked()
            lock.unlock()
        }

        guard let index = records.firstIndex(where: { $0.id == lease.recordID }) else { return }
        if let nativeSessionID, !nativeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records[index].nativeSessionID = nativeSessionID
        }
        if let continuationToken, !continuationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records[index].continuationToken = continuationToken
        }
        if !localContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records[index].localContextSummary = compact(localContextSummary)
        }
        records[index].lastUsedAt = now
        records[index].lastHeartbeatAt = now
        records[index].expiresAt = now.addingTimeInterval(warmTTL)
        records[index].activeCallCount = max(0, records[index].activeCallCount - 1)
    }

    func markFailed(lease: LingShuRemoteSessionLease, now: Date = Date()) {
        lock.lock()
        defer {
            pruneLocked(now: now)
            persistLocked()
            lock.unlock()
        }

        guard let index = records.firstIndex(where: { $0.id == lease.recordID }) else { return }
        records[index].failureCount += 1
        records[index].activeCallCount = max(0, records[index].activeCallCount - 1)
        records[index].lastHeartbeatAt = now
        if records[index].failureCount >= 3 {
            records[index].nativeSessionID = nil
            records[index].continuationToken = nil
        }
    }

    func stats(now: Date = Date()) -> LingShuRemoteSessionPoolStats {
        lock.lock()
        defer { lock.unlock() }

        let onlineRecords = records.filter { $0.expiresAt > now }
        let running = onlineRecords.filter { $0.activeCallCount > 0 }.count
        let expired = records.count - onlineRecords.count
        return .init(
            online: onlineRecords.count,
            running: running,
            standby: max(0, maxHotSessions - onlineRecords.count),
            expired: max(0, expired)
        )
    }

    private func pruneLocked(now: Date) {
        records = records
            .filter { $0.expiresAt > now }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(maxHotSessions)
            .map { $0 }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func loadRecords(defaults: UserDefaults, key: String) -> [LingShuRemoteSessionRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LingShuRemoteSessionRecord].self, from: data)) ?? []
    }

    private func compact(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 900 else { return cleaned }
        return "\(cleaned.prefix(560))\n...远端会话上下文已压缩...\n\(cleaned.suffix(260))"
    }
}
