import Foundation

/// 用户把「你 / 你自己 / 灵枢」作为请求主体时的确定性意图识别。
///
/// 这不是一个任务模板，而是一条通用指代规则：主体已经是灵枢本人时，
/// 不应再反问“课题方向 / 研究领域 / 汇报时长”等外部主题信息；上下文
/// 只影响回答语气与篇幅。只有用户明确要求落盘产出物时，才按任务处理。
enum LingShuSelfReferenceIntent {
    static func isDirectAssistantSelfIntroduction(_ prompt: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(prompt)
        guard asksAboutAssistant(normalized) else { return false }
        return !requestsConcreteDeliverable(normalized)
    }

    static func asksAboutAssistant(_ prompt: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(prompt)
        let directIdentity = [
            "你是谁", "你是什么", "你叫什么", "灵枢是谁", "灵枢是什么",
            "你能做什么", "你的能力", "介绍你的能力", "讲讲你的能力"
        ]
        if directIdentity.contains(where: { normalized.contains($0) }) { return true }

        let introVerbs = ["介绍", "讲讲", "说说", "描述", "说明"]
        let assistantTargets = ["你自己", "你本人", "灵枢", "你"]
        let hasIntro = introVerbs.contains { normalized.contains($0) }
        let hasAssistantTarget = assistantTargets.contains { normalized.contains($0) }
        if hasIntro && hasAssistantTarget { return true }

        return normalized.contains("自我介绍") && (normalized.contains("灵枢") || normalized.contains("你"))
    }

    static func requestsConcreteDeliverable(_ prompt: String) -> Bool {
        let normalized = LingShuMemoryTextToolkit.normalize(prompt)
        let concreteArtifacts = [
            "ppt", "pptx", "keynote", "幻灯片", "演示文稿",
            "pdf", "docx", "word", "markdown", "md", "html",
            "网页", "页面", "代码", "脚本", "程序", "app",
            "文件", "文档", "表格", "图片", "视频", "音频"
        ]
        if concreteArtifacts.contains(where: { normalized.contains($0) }) { return true }

        let artifactVerbs = ["生成", "制作", "做一个", "做个", "写一个", "写个", "输出", "导出", "落盘"]
        let textArtifacts = ["报告", "稿件", "讲稿", "发言稿", "逐字稿", "演讲稿"]
        return artifactVerbs.contains(where: { normalized.contains($0) })
            && textArtifacts.contains(where: { normalized.contains($0) })
    }

    static func directIntroductionGuidance(for prompt: String) -> String? {
        guard isDirectAssistantSelfIntroduction(prompt) else { return nil }
        return """
        【自指介绍规则】
        用户当前是在让你介绍「灵枢本人」。主体已知,不要调用 ask_user/ask_form 反问课题方向、研究领域、老师背景或汇报时长。
        请直接按当前场景组织回答:如果是在汇报/答辩/展示现场,给一段可直接对老师说的简洁介绍;如果只是闲聊,自然自信地介绍自己。
        介绍只讲身份、定位、能给用户带来的价值和当前可落地能力,不暴露内部工具名、底层模型或实现细节。
        """
    }
}
