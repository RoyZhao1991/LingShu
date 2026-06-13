import Foundation

/// skill 危险代码门控：在引入"带可执行脚本"的 skill 前，静态扫描脚本里的高危模式。
///
/// 用户拍板的方向：skill 自迭代不该被限制在纯文本——只要有这道门控把住危险代码，
/// 带脚本的 skill 也能（在门控通过 + 用户授权下）引入。这里只做**高置信度**拦截，
/// 宁可漏判低危、也尽量不误杀正常脚本（如 python-pptx 生成器）；真正执行时仍走授权弹窗兜底。
///
/// 注意：静态扫描挡不住所有恶意（混淆、动态拼接），所以它是**纵深防御的一层**，
/// 不是唯一防线——配合"执行走 run_command 授权弹窗 + 工作目录沙箱"一起用。
enum LingShuSkillSafetyGate {
    struct Verdict: Equatable {
        let isSafe: Bool
        /// 命中的高危项（原因），供 UI/审计展示。
        let violations: [String]
    }

    /// 高危模式：销毁/提权/远程执行/敏感数据/外传。命中任一即拦截。
    private static let dangerous: [(needle: String, reason: String)] = [
        // 销毁性
        ("rm -rf /", "删除根目录/危险递归删除"),
        ("rm -rf ~", "删除用户主目录"),
        ("rm -rf $home", "删除用户主目录"),
        ("rm -fr /", "危险递归删除"),
        ("mkfs", "格式化磁盘"),
        ("dd if=", "裸写磁盘设备"),
        ("diskutil erase", "抹除磁盘"),
        ("> /dev/sd", "写裸磁盘设备"),
        ("> /dev/disk", "写裸磁盘设备"),
        (":(){", "fork 炸弹"),
        ("shutdown", "关机/重启"),
        // 提权
        ("sudo ", "提权执行"),
        ("chmod 777 /", "放开根权限"),
        ("chown -r root", "改根属主"),
        // 远程代码执行（下载即执行）
        ("| sh", "管道执行下载内容（远程代码执行）"),
        ("|sh", "管道执行下载内容（远程代码执行）"),
        ("| bash", "管道执行下载内容（远程代码执行）"),
        ("|bash", "管道执行下载内容（远程代码执行）"),
        ("curl -fssl", "curl 取脚本（常配管道执行）"),
        ("eval \"$(curl", "eval 远程内容"),
        ("eval \"$(wget", "eval 远程内容"),
        ("base64 -d|", "解码后管道执行"),
        ("base64 --decode |", "解码后管道执行"),
        // 敏感数据访问/外传
        ("id_rsa", "读取 SSH 私钥"),
        ("/.ssh/", "访问 SSH 目录"),
        (".aws/credentials", "读取 AWS 凭据"),
        ("/library/keychains", "访问钥匙串"),
        ("security find-generic-password", "导出钥匙串密码"),
        ("owner-profile.json", "读取身份档案"),
        ("credentials.json", "读取凭据文件"),
        ("os.remove('/", "删除根路径文件"),
        ("shutil.rmtree('/", "递归删除根路径")
    ]

    /// 扫描脚本文本，返回裁决。空脚本视为安全（纯提示 skill）。
    static func scan(_ script: String) -> Verdict {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Verdict(isSafe: true, violations: []) }

        // 归一化：去掉转义反斜杠/多余空格干扰，小写匹配。
        let normalized = trimmed
            .replacingOccurrences(of: "\\", with: "")
            .lowercased()

        var violations: [String] = []
        for rule in dangerous where normalized.contains(rule.needle) {
            violations.append(rule.reason)
        }
        // 去重保持稳定。
        let unique = Array(NSOrderedSet(array: violations)) as? [String] ?? violations
        return Verdict(isSafe: unique.isEmpty, violations: unique)
    }
}
