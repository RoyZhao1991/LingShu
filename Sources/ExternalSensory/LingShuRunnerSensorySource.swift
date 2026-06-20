import Foundation

/// **runner 驱动的传感器型外围源**(M2):把一个外围 runner 脚本(子进程,经 P3 沙箱)接成一个标准
/// `LingShuExternalSensorySource`——周期性跑 runner、把 stdout 的 JSON 解析成归一读数 `LingShuExternalSensoryReading`
/// 投进感知流。这是"自编传感器型外围"的执行体:与动作型外围共用同一条**内核 runner 契约③**(stdin/stdout + 沙箱),
/// 只是产出从"工具结果"换成"感知读数"。语言不限(python/node/shell)。
///
/// 设计:`activate()` 起一条轮询 Task(`pollInterval` 拍),每拍跑 runner、解析、yield;`deactivate()` 取消。
/// 纯解析逻辑 `parseReadings` 抽成 static 可单测。隐私 [[perception-data-zero-retention]]:读数只在内存、不落盘。
final class LingShuRunnerSensorySource: LingShuExternalSensorySource, @unchecked Sendable {
    let descriptor: LingShuExternalSensoryDescriptor

    private let manifest: LingShuPluginManifest
    private let executable: String
    private let baseArguments: [String]
    private let channel: LingShuExternalSensoryChannel
    private let sourceID: String
    private let pollInterval: TimeInterval
    private let runOnce: @Sendable (_ manifest: LingShuPluginManifest, _ toolName: String, _ args: String, _ exec: String, _ baseArgs: [String]) async -> String

    private var pollTask: Task<Void, Never>?

    /// - runOnce: 注入跑一次 runner 的实现(默认走 `LingShuPluginToolProvider.runRunner` 沙箱;测试可注入假实现)。
    init(
        descriptor: LingShuExternalSensoryDescriptor,
        manifest: LingShuPluginManifest,
        executable: String,
        baseArguments: [String],
        channel: LingShuExternalSensoryChannel,
        sourceID: String,
        pollInterval: TimeInterval = 5,
        runOnce: @escaping @Sendable (_ manifest: LingShuPluginManifest, _ toolName: String, _ args: String, _ exec: String, _ baseArgs: [String]) async -> String = { m, t, a, e, b in
            await LingShuPluginToolProvider.runRunner(manifest: m, toolName: t, argumentsJSON: a, executable: e, baseArguments: b, sandbox: true, timeout: 20)
        }
    ) {
        self.descriptor = descriptor
        self.manifest = manifest
        self.executable = executable
        self.baseArguments = baseArguments
        self.channel = channel
        self.sourceID = sourceID
        self.pollInterval = max(1, pollInterval)
        self.runOnce = runOnce
    }

    func activate() -> AsyncStream<LingShuExternalSensorySignal> {
        AsyncStream { continuation in
            continuation.yield(.status(.connecting))
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                continuation.yield(.status(.streaming))
                while !Task.isCancelled {
                    let output = await self.runOnce(self.manifest, self.sourceID, "{}", self.executable, self.baseArguments)
                    if Task.isCancelled { break }
                    let readings = Self.parseReadings(output, channel: self.channel, sourceID: self.sourceID)
                    if readings.isEmpty {
                        // runner 没产出可解析读数:不致命(可能本拍无信号),记一条诊断状态,继续轮询。
                        continuation.yield(.status(.streaming))
                    } else {
                        for r in readings { continuation.yield(.reading(r)) }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
                }
                continuation.finish()
            }
            self.pollTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func deactivate() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 纯解析(可单测)

    /// 把 runner 的 stdout 解析成归一读数。接受**单个对象**或**对象数组**;每个对象字段:
    /// `headline`(必填) / `detail` / `salience`(0–3) / `category` / `originApp` / `metadata`(string→string)。
    /// 解析不出合法 headline 的项忽略。错误/空/非 JSON → 空数组(本拍无读数,不致命)。
    static func parseReadings(_ output: String, channel: LingShuExternalSensoryChannel, sourceID: String) -> [LingShuExternalSensoryReading] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let objects: [[String: Any]]
        if let arr = json as? [[String: Any]] { objects = arr }
        else if let obj = json as? [String: Any] { objects = [obj] }
        else { return [] }

        return objects.compactMap { obj -> LingShuExternalSensoryReading? in
            guard let headline = (obj["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty else { return nil }
            var meta: [String: String] = [:]
            if let m = obj["metadata"] as? [String: Any] {
                for (k, v) in m { meta[k] = (v as? String) ?? String(describing: v) }
            }
            let salience: Int
            if let s = obj["salience"] as? Int { salience = s }
            else if let s = obj["salience"] as? Double { salience = Int(s) }
            else { salience = 1 }
            return LingShuExternalSensoryReading(
                channel: channel,
                sourceID: sourceID,
                headline: headline,
                detail: (obj["detail"] as? String)?.nonEmpty,
                category: (obj["category"] as? String)?.nonEmpty,
                originApp: (obj["originApp"] as? String)?.nonEmpty,
                salience: salience,
                metadata: meta
            )
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
