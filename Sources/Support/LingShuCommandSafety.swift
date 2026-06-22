import Foundation

/// shell 命令危险性判定(纯逻辑,可单测)。只拦**真正不可逆/毁数据/越权**的动作,
/// 不拦寻常工程命令——尤其**放行 `> /dev/null` 等标准伪设备重定向**(后台启动服务/静音输出的家常写法)。
///
/// 历史教训(2026-06-21):旧黑名单用宽串 `"> /dev/"` 把 `> /dev/null` 也拦了 → SpringCloud/任何
/// "后台跑服务 + 重定向输出" 的任务在启动验证那步被拒,永远交付不了。现改为**只拦写裸块设备**。
enum LingShuCommandSafety {

    /// 命中=拒绝执行。
    static func isDangerous(_ command: String) -> Bool {
        let s = command.lowercased()
        // 提权/抹盘/关机重启:整类不可逆动作。
        let hardBlocks = ["sudo ", "rm -rf /", "mkfs", "diskutil erase", "shutdown", "reboot", "halt -p"]
        if hardBlocks.contains(where: { s.contains($0) }) { return true }
        // 写**裸块设备**(毁盘):`> /dev/disk` `>> /dev/rdisk` `of=/dev/sda` …
        // 放行标准伪设备:/dev/null·/dev/zero·/dev/stdout·/dev/stderr·/dev/tty·/dev/random·/dev/urandom·/dev/fd/*。
        if s.range(of: #"(>>?\s*|of=)\/dev\/(r?disk|sd|hd|nvme|vd|mmcblk)"#, options: .regularExpression) != nil { return true }
        return false
    }
}
