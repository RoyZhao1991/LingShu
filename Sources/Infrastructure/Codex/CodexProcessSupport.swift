import Foundation

/// Codex 子进程的取消句柄：线程安全地挂接/终止一个正在执行的 Process。
final class CodexExecutionHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel {
            self.process = process
        }
        lock.unlock()

        if shouldCancel, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let processToCancel = process
        process = nil
        lock.unlock()

        if let processToCancel, processToCancel.isRunning {
            processToCancel.terminate()
        }
    }

    func detach(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }
}

/// 线程安全地累积 Codex 子进程的 stdout/stderr，并把增量回调给流式进度。
final class CodexStreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var lastActivityAt = Date()
    private let progress: ((String) -> Void)?

    init(progress: ((String) -> Void)?) {
        self.progress = progress
    }

    func capture(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }

        lock.lock()
        if isError {
            stderrData.append(data)
        } else {
            stdoutData.append(data)
        }
        lastActivityAt = Date()
        lock.unlock()

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            progress?(text)
        }
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }

    var lastActivity: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastActivityAt
    }

    func markHeartbeat() {
        lock.lock()
        lastActivityAt = Date()
        lock.unlock()
    }
}
