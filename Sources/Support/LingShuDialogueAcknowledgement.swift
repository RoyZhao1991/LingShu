import Foundation

struct LingShuDialogueAcknowledgement {
    /// 思考占位不再用机械的第一人称独白；返回空串，界面只显示一个安静的思考指示，
    /// 等真实回复一到就替换。避免每轮都甩同一句“我先判断这件事…”的人机感。
    func intake(for prompt: String) -> String {
        ""
    }

    func routeReply(
        for route: CodexRoutePayload,
        fallback: String,
        willExecute: Bool
    ) -> String {
        guard route.needsAgents else {
            let direct = route.currentUserReply.trimmingCharacters(in: .whitespacesAndNewlines)
            return direct.isEmpty ? fallback : direct
        }

        guard willExecute else {
            let planned = route.currentUserReply.trimmingCharacters(in: .whitespacesAndNewlines)
            return planned.isEmpty ? fallback : planned
        }

        // 会真正进入执行线程时：优先用模型这轮**带情境感知**的简短致意（时间/历史/氛围，自然贴合此刻）。
        // 但要挡住降级——模型常把 currentReply 写成"你存成 xx.py 跑一下"的脚本搪塞冒充交付；
        // 一旦闻到脚本甩锅味就丢弃、回退干净回执。真正的交付物（真 .pptx 等）由后台目标循环产出回传。
        let currentReply = route.currentReply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !currentReply.isEmpty, !Self.looksLikeScriptHandoff(currentReply) {
            return currentReply
        }

        let agentNames = route.agents
            .map(\.agent)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "、")
        let assignee = agentNames.isEmpty ? "相关能力节点" : agentNames
        return "收到。这件事需要能力节点协作，我已分派给 \(assignee)。后台正在执行，我会把结果回传给你。"
    }

    /// 闻到"给你段脚本/你自己跑一下"的甩锅味——这类降级不能当成首条交付回执。
    static func looksLikeScriptHandoff(_ text: String) -> Bool {
        let markers = [
            "存成", "保存为", "跑一下", "运行一下", "自己跑", "自己运行", "复制保存",
            ".py", ".sh", "```", "make_", "pip install", "python3 ", "python ", "brew install"
        ]
        return markers.contains { text.contains($0) }
    }
}
