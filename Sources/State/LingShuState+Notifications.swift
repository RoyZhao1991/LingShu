import Foundation

/// 系统通知四肢:给大脑一个 `push_notification` 工具,主动推 macOS 通知横幅给主人。
@MainActor
extension LingShuState {
    /// 推系统通知工具(主动提醒:会议纪要已生成、发现需留意的问题、长任务完成…)。
    func pushNotificationTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "push_notification",
            description: "推送一条 macOS 系统通知横幅给主人(主动提醒)。适用于:会议纪要已生成、发现需留意的异常、长任务完成等——主人不在电脑前也能在通知中心看到。日常闲聊不要用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"通知标题(简短)\"},\"body\":{\"type\":\"string\",\"description\":\"通知正文(一两句)\"}},\"required\":[\"title\",\"body\"]}"
        ) { argumentsJSON in
            let title = Self.jsonField(argumentsJSON, "title") ?? "灵枢"
            let body = Self.jsonField(argumentsJSON, "body") ?? argumentsJSON
            return await MainActor.run {
                LingShuNotificationCenter.shared.post(title: title, body: body)
                return "已推送系统通知:\(title) — \(body.prefix(40))"
            }
        }
    }
}
