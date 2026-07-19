import Foundation

/// 完全版 #8·审查视图的 git 后端(基础设施层——视图/模型不直接碰 `Process`,经此调用)。
/// 只读 `git diff` + 反向应用补丁(回退未接受的 hunk)。工作目录内执行。
enum LingShuWorkspaceReviewGit {
    static func diff(dir: String) -> String { run(["-C", dir, "diff"]).out }

    /// 把补丁反向应用(回退其代表的改动)。成功=退出码 0。`--recount` 容忍行号小偏差。
    static func applyReverse(patch: String, dir: String) -> Bool {
        let tmp = LingShuRuntimeEnvironment.temporaryDirectoryPath + "lsrev-\(UUID().uuidString).patch"
        guard (try? patch.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        return run(["-C", dir, "apply", "--reverse", "--recount", tmp]).code == 0
    }

    private static func run(_ args: [String]) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return ("git 启动失败:\(error.localizedDescription)", 1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
