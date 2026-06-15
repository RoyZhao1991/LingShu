import Foundation

/// 系统命令分级策略（纯函数,可单测；executor 与 state 工具桥共用）。
///
/// 两个判定:
/// - `isReadOnly`:命令是否**纯只读**(grep/find/ls/cat… + git status 这类)。只读命令免审批直接放行,
///   大脑 grep/find 定位时不再每次弹框打断(对应计划 §3)。
/// - `touchesSystemSensitivePath`:命令是否**删除/修改系统级敏感文件**(/System、/usr、/bin、/etc、引导/内核扩展…)。
///   独立运行=完整电脑控制、其余动作不再要授权,**唯独这类系统级破坏性操作除外**——即使「完整授权」也强制弹一次审批
///   (无人值守则安全拒绝)(对应计划 §1 的红线)。
enum LingShuShellCommandPolicy {

    // MARK: - 只读命令白名单（免审批）

    /// 纯只读的命令名(参数无副作用)。复合命令(管道/&&/;)要求**每一段**都在此集合内才算只读。
    private static let readOnlyCommands: Set<String> = [
        "grep", "egrep", "fgrep", "rg", "ag", "ack",
        "find", "fd",
        "ls", "ll", "tree",
        "cat", "bat", "head", "tail", "less", "more",
        "wc", "file", "stat", "du", "df",
        "echo", "printf", "pwd", "whoami", "id", "hostname", "uname", "date", "env",
        "which", "type", "command", "basename", "dirname", "realpath",
        "sort", "uniq", "cut", "tr", "column", "nl", "diff", "comm", "cmp",
        "true", "false", "test"
    ]

    /// 只读的 git 子命令(读仓库状态/历史/差异,不改工作区/索引/远端)。
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "branch", "remote", "config",
        "blame", "shortlog", "describe", "rev-parse", "ls-files", "ls-tree",
        "cat-file", "tag", "stash", "reflog", "whatchanged", "grep"
    ]

    /// 出现这些字符/词即**不算只读**(重定向写、删改、提权、网络下载等),无论命令名是什么。
    private static let writeOrUnsafeMarkers: [String] = [
        ">", ">>", "rm ", "rmdir", "mv ", "cp ", "dd ", "tee ", "ln ",
        "mkdir", "touch", "chmod", "chown", "chgrp", "truncate",
        "sudo", "su ", "kill", "pkill", "killall", "shutdown", "reboot",
        "install", "uninstall", "pip ", "pip3 ", "npm ", "brew ", "gem ", "cargo ",
        "curl", "wget", "scp", "rsync", "ssh", "nc ", "ftp",
        "git add", "git commit", "git push", "git pull", "git fetch", "git checkout",
        "git reset", "git rm", "git mv", "git merge", "git rebase", "git clean",
        "git restore", "git switch", "git apply", "git stash push", "git stash pop",
        "defaults write", "launchctl", "crontab", "osascript", "open "
    ]

    /// 命令是否**纯只读**——免审批直接放行的判定。保守:任一不确定即返回 false(宁可弹框)。
    static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()

        // 任一写/危险标记出现 → 直接判非只读。
        if writeOrUnsafeMarkers.contains(where: { lowered.contains($0) }) { return false }
        // 命令替换可能藏写操作,保守起见不当只读。
        if lowered.contains("$(") || lowered.contains("`") { return false }

        // 按管道/逻辑连接符/分号拆段,每段首词都必须是只读命令。
        let segments = splitSegments(lowered)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            let tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = tokens.first else { return false }
            if head == "git" {
                guard let sub = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }),
                      readOnlyGitSubcommands.contains(sub) else { return false }
            } else if !readOnlyCommands.contains(head) {
                return false
            }
        }
        return true
    }

    // MARK: - 系统级敏感路径（删除/修改即强制审批）

    /// 系统级敏感目录前缀(删/改其中文件 = 高危,需人工裁决)。/usr/local 与用户目录不在此列。
    private static let systemSensitivePrefixes: [String] = [
        "/system", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/",
        "/etc/", "/private/etc/", "/private/var/db/", "/library/launchdaemons",
        "/library/launchagents", "/library/extensions", "/library/preferences/systemconfiguration",
        "/library/security", "/var/db/", "/.vol/", "/dev/"
    ]

    /// 会改动文件系统的命令名(配合敏感路径判定;只读命令即便提到敏感路径也无破坏性)。
    private static let mutatingCommands: [String] = [
        "rm", "rmdir", "mv", "cp", "dd", "tee", "ln", "chmod", "chown", "chgrp",
        "truncate", "mkfs", "diskutil", "rsync", "install", "ditto", "touch", "mkdir",
        "kextload", "kextunload", "csrutil", "nvram", "pmset", "scutil"
    ]

    /// 命令是否会**删除/修改系统级敏感文件**。判定:含改动型命令 + 引用了系统敏感路径,或命中明确高危词。
    /// 即使「完整授权」也要对它强制弹一次审批(计划 §1 红线)。
    static func touchesSystemSensitivePath(_ command: String) -> Bool {
        let lowered = command.lowercased()

        // 明确的全局灾难性操作,任何模式一律视作系统敏感。
        let catastrophic = ["mkfs", "diskutil erase", "> /dev/", "csrutil disable", "nvram "]
        if catastrophic.contains(where: { lowered.contains($0) }) { return true }
        // 针对根目录的毁灭性删除(rm / 或 /*)——词级判定,避免 "rm -rf /Users/..." 被子串误命中。
        let tokens = lowered.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if tokens.first == "rm" {
            let targets = tokens.dropFirst().filter { !$0.hasPrefix("-") }
            if targets.contains(where: { $0 == "/" || $0 == "/*" || $0 == "/." || $0 == "~" }) { return true }
        }

        // 重定向写入系统敏感路径也算(与命令名无关:echo x > /etc/passwd 也要拦)。
        let redirectPrefixes = ["> /system", ">/system", "> /etc", ">/etc", "> /bin", ">/bin",
                                "> /usr/bin", ">/usr/bin", "> /sbin", ">/sbin", "> /library", ">/library"]
        if redirectPrefixes.contains(where: { lowered.contains($0) }) { return true }

        let hasMutator = mutatingCommands.contains { cmd in
            // 词边界:命令名后跟空格(避免 "remove" 命中 "rm")。
            lowered.contains(cmd + " ") || lowered.hasSuffix(cmd)
        }
        guard hasMutator else { return false }
        return systemSensitivePrefixes.contains { lowered.contains($0) }
    }

    // MARK: - 工具

    private static func splitSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // 连接符:| || & && ;
            if c == "|" || c == "&" {
                segments.append(current); current = ""
                if i + 1 < chars.count, chars[i + 1] == c { i += 1 }   // 跳过第二个 | 或 &
            } else if c == ";" {
                segments.append(current); current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        segments.append(current)
        return segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
