import Foundation

struct LingShuIntentClarificationDecision: Equatable {
    var question: String
    var reason: String
}

struct LingShuPendingIntentClarification {
    var originalPrompt: String
    var recordID: String?
    var question: String
    var createdAt: Date
}

struct LingShuIntentClarificationPolicy {
    func clarification(
        for prompt: String,
        memoryContext: MainThreadMemoryContext,
        focusedTaskTitle: String? = nil
    ) -> LingShuIntentClarificationDecision? {
        let normalized = normalize(prompt)
        guard !normalized.isEmpty else { return nil }

        if isIdentityOrGreeting(normalized) {
            return nil
        }

        let contextTitle = focusedTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? memoryContext.hotMatches.first?.title
            ?? memoryContext.coldMatches.first?.title

        if isBareContinuation(normalized) {
            if let contextTitle, !contextTitle.isEmpty {
                return .init(
                    question: "我需要确认一下：你是要继续“\(compact(contextTitle, limit: 22))”这件事，还是另起一个新任务？",
                    reason: "用户只表达继续，但没有明确继续对象。"
                )
            }

            return .init(
                question: "我需要确认一下：你想让我继续哪件事？告诉我目标或产出物后，我再推进。",
                reason: "用户只表达继续，且没有可可靠续接的上下文。"
            )
        }

        // 落地优先：用户给出动作但没有任何对象（如只说「处理一下」），才需要问；
        // 一旦点名了交付物（PPT/代码/文档/页面…），即便主题/受众/格式没说全，也直接按
        // 合理默认产出，事后再让用户改，而不是先抛三连问。
        if isVagueAction(normalized) {
            return .init(
                question: "我需要先确认你的目标：你想让我处理哪件事，最终要交付什么？",
                reason: "用户给出动作，但缺少对象、范围或交付口径。"
            )
        }

        if hasUnresolvedReference(normalized, memoryContext: memoryContext, focusedTaskTitle: focusedTaskTitle) {
            if let contextTitle, !contextTitle.isEmpty {
                return .init(
                    question: "你说的“这个”是指“\(compact(contextTitle, limit: 22))”吗？确认后我再继续推进。",
                    reason: "用户使用指代词，虽然有历史上下文，但仍需要确认对象。"
                )
            }

            return .init(
                question: "你说的“这个”具体指哪一项？把对象或目标补一句，我再推进。",
                reason: "用户使用指代词，但当前没有可靠上下文。"
            )
        }

        return nil
    }

    func isCancellation(_ prompt: String) -> Bool {
        let normalized = normalize(prompt)
        return [
            "取消", "不用了", "不用", "先不用", "不要了", "别做了",
            "停", "停止", "暂停", "算了", "先不处理", "先放着"
        ].contains { normalized.contains($0) }
    }

    func clarifiedPrompt(originalPrompt: String, clarificationAnswer: String) -> String {
        """
        原始需求：
        \(originalPrompt)

        用户补充说明：
        \(clarificationAnswer)

        请基于原始需求和补充说明，重新判断真实意图；如果仍然不确定，继续向用户澄清，不要盲目执行。
        """
    }

    private func isIdentityOrGreeting(_ normalized: String) -> Bool {
        [
            "你是谁", "你是什么", "你叫什么", "灵枢是谁",
            "你好", "您好", "在吗", "hello", "hi"
        ].contains(normalized)
    }

    private func isBareContinuation(_ normalized: String) -> Bool {
        [
            "继续", "继续吧", "接着", "接着来", "往下", "继续推进",
            "继续处理", "继续做", "下一步", "继续执行"
        ].contains(normalized)
    }

    private func isVagueAction(_ normalized: String) -> Bool {
        let exactVague = [
            "处理一下", "帮我处理一下", "弄一下", "帮我弄一下",
            "搞一下", "帮我搞一下", "改一下", "优化一下",
            "调整一下", "完善一下", "推进一下", "做一下",
            "修一下", "看一下", "检查一下", "帮我做一下"
        ]
        if exactVague.contains(normalized) {
            return true
        }

        let vagueActions = ["处理", "优化", "调整", "完善", "推进", "修", "改", "弄", "搞", "做"]
        guard normalized.count <= 8,
              vagueActions.contains(where: { normalized.contains($0) }) else {
            return false
        }

        return !hasConcreteTarget(normalized)
    }

    private func hasUnresolvedReference(
        _ normalized: String,
        memoryContext: MainThreadMemoryContext,
        focusedTaskTitle: String?
    ) -> Bool {
        let referenceSignals = ["这个", "那个", "它", "上面", "刚才那个", "这件事", "那个问题"]
        guard referenceSignals.contains(where: { normalized.contains($0) }) else { return false }

        if normalized.count <= 14 {
            return true
        }

        let hasReliableContext = focusedTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || memoryContext.shouldLoadHistory
        return !hasReliableContext
    }

    private func hasConcreteTarget(_ normalized: String) -> Bool {
        let concreteSignals = [
            "灵枢", "安全票夹", "receiptvault", "app", "ios", "mac", "项目",
            "代码", "页面", "接口", "爬虫", "web", "ppt", "汇报", "课题",
            "架构", "流程", "权限", "语音", "视觉", "模型", "配置",
            "任务", "队列", "测试", "构建", "报错", "文件", "文档",
            "报告", "设计", "演示", "图表", "数据库"
        ]
        return concreteSignals.contains { normalized.contains($0) }
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "；", with: "")
            .replacingOccurrences(of: ";", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))..."
    }
}
