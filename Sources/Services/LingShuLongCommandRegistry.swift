import Darwin
import Foundation

enum LingShuLongCommandStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut

    var isTerminal: Bool {
        switch self {
        case .running: return false
        case .succeeded, .failed, .cancelled, .timedOut: return true
        }
    }
}

struct LingShuLongCommandSnapshot: Equatable, Sendable {
    let id: String
    let label: String
    let command: String
    let workingDirectory: String
    let logPath: String
    let pid: Int32?
    let status: LingShuLongCommandStatus
    let exitCode: Int?
    let startedAt: Date
    let endedAt: Date?
    let timeoutSeconds: TimeInterval
    let reusedExisting: Bool
    let tail: String

    var durationSeconds: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var modelText: String {
        let statusText: String
        switch status {
        case .running: statusText = "运行中"
        case .succeeded: statusText = "已完成"
        case .failed: statusText = "失败"
        case .cancelled: statusText = "已取消"
        case .timedOut: statusText = "超时终止"
        }
        let reused = reusedExisting ? "（复用已有同命令 job，未重复启动）" : ""
        let code = exitCode.map { "，退出码 \($0)" } ?? ""
        let body = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        长命令 \(statusText)\(reused)
        job_id: \(id)
        pid: \(pid.map(String.init) ?? "-")
        用时: \(String(format: "%.1f", durationSeconds))s\(code)
        日志: \(logPath)
        \(body.isEmpty ? "（暂无日志输出）" : "\n最近日志:\n\(body)")
        """
    }
}

/// 宿主托管的长命令注册表。
///
/// `run_command` 必须保持有界返回；超过几分钟的构建、测试、转换、下载、服务启动应进入这里：
/// 一次启动拿到 job_id，后续查询/取消均通过 job_id，且相同工作目录 + 命令运行中会自动复用，避免重复压测/重复构建。
@MainActor
final class LingShuLongCommandRegistry {
    private final class Job {
        let id: String
        let signature: String
        let label: String
        let command: String
        let workingDirectory: String
        let logPath: String
        let startedAt: Date
        let timeoutSeconds: TimeInterval
        let process: Process
        let logHandle: FileHandle
        var status: LingShuLongCommandStatus = .running
        var exitCode: Int?
        var endedAt: Date?
        var timeoutTask: Task<Void, Never>?
        var logClosed = false

        init(id: String, signature: String, label: String, command: String, workingDirectory: String, logPath: String, startedAt: Date, timeoutSeconds: TimeInterval, process: Process, logHandle: FileHandle) {
            self.id = id
            self.signature = signature
            self.label = label
            self.command = command
            self.workingDirectory = workingDirectory
            self.logPath = logPath
            self.startedAt = startedAt
            self.timeoutSeconds = timeoutSeconds
            self.process = process
            self.logHandle = logHandle
        }
    }

    private var jobs: [String: Job] = [:]
    private var runningSignatureIndex: [String: String] = [:]
    private let logDirectory: URL

    init(logDirectory: URL = LingShuLongCommandRegistry.defaultLogDirectory()) {
        self.logDirectory = logDirectory
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    static func defaultLogDirectory() -> URL {
        let base = LingShuRuntimeEnvironment.applicationSupportDirectory()
        return base.appendingPathComponent("LingShu/long-commands", isDirectory: true)
    }

    @discardableResult
    func start(command rawCommand: String, workingDirectory rawWorkingDirectory: String, label rawLabel: String?, timeoutSeconds rawTimeoutSeconds: TimeInterval?) -> LingShuLongCommandSnapshot {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = NSString(string: rawWorkingDirectory).expandingTildeInPath
        let label = (rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyLongCommand) ?? String(command.prefix(48))
        let timeoutSeconds = Self.normalizedTimeout(rawTimeoutSeconds)
        let signature = Self.signature(command: command, workingDirectory: workingDirectory)

        if let existingID = runningSignatureIndex[signature], let existing = jobs[existingID], existing.status == .running {
            return snapshot(for: existing, reusedExisting: true)
        }

        guard !command.isEmpty else {
            return failedSyntheticSnapshot(label: label, command: command, workingDirectory: workingDirectory, reason: "命令为空。")
        }
        guard FileManager.default.fileExists(atPath: workingDirectory) else {
            return failedSyntheticSnapshot(label: label, command: command, workingDirectory: workingDirectory, reason: "工作目录不存在:\(workingDirectory)")
        }

        let id = "long-\(UUID().uuidString.prefix(8))"
        let logPath = logDirectory.appendingPathComponent("\(id).log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) else {
            return failedSyntheticSnapshot(label: label, command: command, workingDirectory: workingDirectory, reason: "无法创建长命令日志:\(logPath)")
        }

        appendLog(handle, """
        [lingshu] job_id=\(id)
        [lingshu] started_at=\(ISO8601DateFormatter().string(from: Date()))
        [lingshu] working_directory=\(workingDirectory)
        [lingshu] command=\(command)

        """)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle

        let startedAt = Date()
        let job = Job(
            id: id,
            signature: signature,
            label: label,
            command: command,
            workingDirectory: workingDirectory,
            logPath: logPath,
            startedAt: startedAt,
            timeoutSeconds: timeoutSeconds,
            process: process,
            logHandle: handle
        )
        jobs[id] = job
        runningSignatureIndex[signature] = id

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.finish(id: id, status: process.terminationStatus == 0 ? .succeeded : .failed, exitCode: Int(process.terminationStatus))
            }
        }

        do {
            try process.run()
        } catch {
            finish(id: id, status: .failed, exitCode: nil, extraLog: "启动失败:\(error.localizedDescription)")
            return snapshot(id: id) ?? failedSyntheticSnapshot(label: label, command: command, workingDirectory: workingDirectory, reason: "启动失败:\(error.localizedDescription)")
        }

        job.timeoutTask = Task { [weak self] in
            let nanos = UInt64(timeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await MainActor.run {
                self?.timeout(id: id)
            }
        }

        return snapshot(for: job, reusedExisting: false)
    }

    func snapshot(id: String) -> LingShuLongCommandSnapshot? {
        guard let job = jobs[id] else { return nil }
        return snapshot(for: job, reusedExisting: false)
    }

    func snapshots() -> [LingShuLongCommandSnapshot] {
        jobs.values
            .sorted { $0.startedAt > $1.startedAt }
            .map { snapshot(for: $0, reusedExisting: false) }
    }

    func cancel(id: String) -> LingShuLongCommandSnapshot? {
        guard let job = jobs[id] else { return nil }
        guard job.status == .running else { return snapshot(for: job, reusedExisting: false) }
        terminateProcessTree(rootPID: job.process.processIdentifier)
        finish(id: id, status: .cancelled, exitCode: nil, extraLog: "用户取消长命令。")
        return snapshot(for: job, reusedExisting: false)
    }

    private func timeout(id: String) {
        guard let job = jobs[id], job.status == .running else { return }
        terminateProcessTree(rootPID: job.process.processIdentifier)
        finish(id: id, status: .timedOut, exitCode: nil, extraLog: "\(Int(job.timeoutSeconds))s 达到长命令超时上限，已终止进程树。")
    }

    private func finish(id: String, status: LingShuLongCommandStatus, exitCode: Int?, extraLog: String? = nil) {
        guard let job = jobs[id] else { return }
        guard job.status == .running else {
            closeLogIfNeeded(job)
            return
        }
        job.status = status
        job.exitCode = exitCode
        job.endedAt = Date()
        job.timeoutTask?.cancel()
        runningSignatureIndex[job.signature] = nil
        if let extraLog, !extraLog.isEmpty {
            appendLog(job.logHandle, "\n[lingshu] \(extraLog)\n")
        }
        appendLog(job.logHandle, "[lingshu] ended_at=\(ISO8601DateFormatter().string(from: job.endedAt ?? Date())) status=\(status.rawValue) exit_code=\(exitCode.map(String.init) ?? "-")\n")
        closeLogIfNeeded(job)
    }

    private func closeLogIfNeeded(_ job: Job) {
        guard !job.logClosed else { return }
        job.logClosed = true
        try? job.logHandle.synchronize()
        try? job.logHandle.close()
    }

    private func snapshot(for job: Job, reusedExisting: Bool) -> LingShuLongCommandSnapshot {
        LingShuLongCommandSnapshot(
            id: job.id,
            label: job.label,
            command: job.command,
            workingDirectory: job.workingDirectory,
            logPath: job.logPath,
            pid: job.process.processIdentifier,
            status: job.status,
            exitCode: job.exitCode,
            startedAt: job.startedAt,
            endedAt: job.endedAt,
            timeoutSeconds: job.timeoutSeconds,
            reusedExisting: reusedExisting,
            tail: Self.tail(path: job.logPath)
        )
    }

    private func failedSyntheticSnapshot(label: String, command: String, workingDirectory: String, reason: String) -> LingShuLongCommandSnapshot {
        let now = Date()
        return LingShuLongCommandSnapshot(
            id: "long-invalid",
            label: label,
            command: command,
            workingDirectory: workingDirectory,
            logPath: "",
            pid: nil,
            status: .failed,
            exitCode: nil,
            startedAt: now,
            endedAt: now,
            timeoutSeconds: Self.normalizedTimeout(nil),
            reusedExisting: false,
            tail: reason
        )
    }

    private func appendLog(_ handle: FileHandle, _ text: String) {
        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        }
    }

    private static func normalizedTimeout(_ raw: TimeInterval?) -> TimeInterval {
        let value = raw ?? 3600
        return min(max(value, 30), 86_400)
    }

    private static func signature(command: String, workingDirectory: String) -> String {
        let normalizedCommand = command
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return "\(NSString(string: workingDirectory).standardizingPath)\n\(normalizedCommand)"
    }

    private static func tail(path: String, maxBytes: Int = 6000) -> String {
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
        return String(data: Data(data.suffix(maxBytes)), encoding: .utf8) ?? ""
    }

    private func terminateProcessTree(rootPID: Int32) {
        let descendants = Self.descendantPIDs(of: rootPID)
        for pid in descendants.reversed() {
            kill(pid, SIGTERM)
        }
        kill(rootPID, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            for pid in descendants.reversed() {
                kill(pid, SIGKILL)
            }
            kill(rootPID, SIGKILL)
        }
    }

    private static func descendantPIDs(of pid: Int32) -> [Int32] {
        let children = childPIDs(of: pid)
        return children + children.flatMap { descendantPIDs(of: $0) }
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

private extension String {
    var nonEmptyLongCommand: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
