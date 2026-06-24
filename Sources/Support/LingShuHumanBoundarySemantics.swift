import Foundation

/// 人类参与边界的通用语义。
///
/// 原则:真正需要用户介入的前提必须指向受保护对象或高风险动作;单独的
/// "用户/主人/我" 只是交互参与者,不能被模型当成一个待授权的能力对象。
enum LingShuHumanBoundarySemantics {
    static func isBareHumanActorTarget(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "：", with: ":")
            .trimmingCharacters(in: CharacterSet(charactersIn: "「」[]()（）:：;；,，.。"))
        let actors: Set<String> = [
            "用户", "用户本人", "使用者", "主人", "我", "本人", "人类",
            "user", "theuser", "human", "operator"
        ]
        return actors.contains(normalized)
    }

    static func containsConcreteProtectedBoundary(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        let signals = [
            "第三方", "外部", "服务", "工作区", "账号", "账户", "密码", "token", "api key", "apikey", "oauth",
            "支付", "付款", "扣款", "转账", "付费", "删除", "生产", "高风险", "危险",
            "物理", "设备", "外设", "机器人", "开灯", "关灯", "接管", "屏幕录制", "辅助功能",
            "系统权限", "隐私权限", "本地网络", "局域网", "蓝牙", "bonjour", "mdns",
            "投屏", "airplay", "chromecast",
            "notion", "slack", "github", "gmail", "google", "jira", "飞书", "钉钉", "微信", "企业微信"
        ]
        return signals.contains { lower.contains($0.lowercased()) }
    }
}
