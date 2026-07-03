import Foundation

/// 通用交互交付判定:当用户要的不是"生成一个文件"本身,而是"把结果展示/讲解/演示给我看"时,
/// 产出物落盘不等于任务完成。这里不关心 PPT/代码等领域,只判断是否欠一个可感知输出动作。
enum LingShuInteractionFulfillment {
    private static let previewExtensions: Set<String> = [
        "html", "htm", "pdf", "pptx", "docx", "xlsx", "md", "txt", "png", "jpg", "jpeg"
    ]

    nonisolated static func requiresVisibleInteraction(_ text: String) -> Bool {
        let value = text.lowercased()
        guard !value.isEmpty else { return false }

        let explicitPreview = [
            "打开预览", "普通预览", "预览窗口", "预览版本", "给我看", "展示给", "带我看",
            "演示", "放映", "讲解", "讲给", "念给", "读给", "播报", "现场答疑",
            "present", "presentation", "slideshow", "show me", "walk me through"
        ].contains { value.contains($0.lowercased()) }
        if explicitPreview { return true }

        let reportContext = ["汇报", "陈述", "答辩", "路演"].contains { value.contains($0) }
        let presentationArtifact = ["ppt", "pptx", "幻灯片", "演示文稿", "deck", "slides"].contains { value.contains($0.lowercased()) }
        return reportContext && presentationArtifact
    }

    /// 是否进入"实时交互交付"范式:主人要的不是静态文件,而是现场看、听、追问、继续。
    /// 这里不绑定 PPT/报告等领域,只看交互意图;单纯"生成材料"不会命中。
    nonisolated static func requiresLiveInteraction(_ text: String) -> Bool {
        let value = text.lowercased()
        guard !value.isEmpty, !forbidsManagedInteraction(value) else { return false }
        // **审计 #1(2026-06-26):只保留「显式控制命令」做确定性保险丝**(用户明确要进占屏/托管放映)——
        // 这类是用户的显式指令,确定性直达合理。**领域/含糊词(汇报/讲解/答疑/带我看/路演/demo…)已移除**:
        // 它们只是「上下文信号」,不该硬决定流程,交给大脑(看 prompt + GoalSpec,需要时自己调 enter_managed_mode)判。
        let liveSignals = [
            "开始演示", "全屏演示", "进入演示", "放映", "占屏", "自主模式", "托管模式", "全自动播放",
            "present", "presentation", "slideshow"
        ]
        return liveSignals.contains { value.contains($0.lowercased()) }
    }

    nonisolated static func isLikelyInteractionFollowup(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let followups = [
            "继续", "下一页", "上一页", "翻页", "这页", "刚才", "基于刚才", "老师提问",
            "答疑", "再讲", "接着讲", "接着说", "往下说", "讲细点", "展开说", "收尾", "结束演示", "关闭预览",
            "continue", "next page", "previous page", "question", "q&a"
        ]
        return followups.contains { value.contains($0.lowercased()) }
    }

    /// 可视交互中的提问/答疑意图。它只决定"最终回复必须回答问题",不决定任务路由。
    nonisolated static func isQuestionLike(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value.contains("?") || value.contains("？") { return true }
        let signals = [
            "老师提问", "提问", "答疑", "请回答", "回答一下", "解释一下", "说明一下",
            "为什么", "怎么", "如何", "是什么", "什么是", "区别", "相比", "价值",
            "是否", "能否", "可否", "哪里", "哪个", "哪种", "多少", "吗", "呢"
        ]
        return signals.contains { value.contains($0.lowercased()) }
    }

    nonisolated static func isVisiblePresentationControl(_ text: String) -> Bool {
        if isQuestionLike(text) { return false }
        return isContinuePresentationCommand(text) || isNextPageCommand(text) || isPreviousPageCommand(text)
    }

    nonisolated static func isContinuePresentationCommand(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let commands = [
            "继续", "接着", "往下讲", "接着往下", "继续演示", "继续讲", "往后讲",
            "从当前", "讲下一页", "往下翻着讲", "continue", "keep going", "go on"
        ]
        return commands.contains { value.contains($0.lowercased()) }
    }

    nonisolated static func isNextPageCommand(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let commands = ["下一页", "翻页", "往后翻", "next page", "next slide"]
        return commands.contains { value.contains($0.lowercased()) }
    }

    nonisolated static func isPreviousPageCommand(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let commands = ["上一页", "往前翻", "回上一页", "previous page", "previous slide"]
        return commands.contains { value.contains($0.lowercased()) }
    }

    nonisolated static func isHollowInteractionStatus(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return true }
        let hollowSignals = [
            "已完成答疑", "完成答疑", "已基于", "当前继续停在", "等待老师", "等待后续",
            "已讲解", "已播报", "已处理", "已整理", "已完成"
        ]
        let hasHollowSignal = hollowSignals.contains { compact.contains($0) }
        let substanceSignals = ["因为", "首先", "第一", "第二", "第三", "核心", "价值", "区别", "在于", "通过", "所以"]
        let hasSubstance = substanceSignals.contains { compact.contains($0) }
        if hasHollowSignal && !hasSubstance { return true }
        return compact.count < 46 && hasHollowSignal
    }

    /// 页面讲解状态不是答疑正文。用户问问题时,不能把这类状态当成最终答案。
    nonisolated static func isPageNarrationStatus(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return false }
        if compact.contains("主要说明") && compact.contains("第") && compact.contains("页") { return true }
        if compact.contains("页面要点") && compact.contains("当前停在第") { return true }
        if compact.contains("我先根据画面继续讲") { return true }
        return false
    }

    /// 交互交付场景里的“产出物库存式回复”:文件路径/表格/清单本身不是演示或讲解正文。
    /// 这不是针对 PPT 的规则;任何“展示/讲解/演示/带人看”的任务,最终聊天气泡都应描述当前可感知状态,
    /// 而不是把内部落盘路径当成主要回复。路径仍保留在任务记录和产出物清单里供追溯。
    nonisolated static func isArtifactInventoryStatus(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let pathPattern = #"/[^\s`"'）)，。、；;】|]+?\.(?:py|txt|md|json|csv|pdf|docx|pptx|html?|wav|mp3|png|jpg|jpeg)"#
        let pathCount = value.matches(of: try! Regex(pathPattern)).count
        let tableLike = value.contains("|") && value.contains("---")
        let inventoryTerms = ["产出物", "文件", "路径", "已生成", "交付物", "artifact", "output"]
            .filter { value.lowercased().contains($0.lowercased()) }
            .count
        let quotedAbsolutePath = value.contains("`/") || value.contains("\"/")
        let pathColumn = value.contains("路径") && tableLike
        let extensionMention = [
            ".py", ".txt", ".md", ".json", ".csv", ".pdf", ".docx", ".pptx", ".html", ".htm", ".wav", ".mp3", ".png", ".jpg", ".jpeg"
        ].contains { value.lowercased().contains($0) }
        let hasPathEvidence = pathCount > 0 || quotedAbsolutePath || pathColumn || extensionMention
        return hasPathEvidence && (tableLike || inventoryTerms >= 2)
    }

    /// 比 `isArtifactInventoryStatus` 更宽的交付清单判定。只应在"用户明确要展示/讲解/演示"且已有可感知输出时使用,
    /// 用来避免模型把"文件列表"当成现场讲解/演示的最终回复。
    nonisolated static func isLikelyDeliveryInventoryStatus(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let tableLike = value.contains("|") && value.contains("---")
        let hasInventoryHeader = ["产出物", "交付物", "文件", "路径", "output", "artifact"]
            .contains { value.contains($0.lowercased()) }
        let hasCompletionHeader = ["全部完成", "已完成", "完整交付", "最终交付", "current status", "当前状态"]
            .contains { value.contains($0.lowercased()) }
        let hasPreviewOrFileMention = [
            ".pptx", ".pdf", ".html", ".htm", ".docx", ".xlsx", ".md", "预览", "全屏演示", "打开", "路径"
        ].contains { value.contains($0.lowercased()) }
        return (tableLike && hasInventoryHeader)
            || (hasCompletionHeader && hasInventoryHeader && hasPreviewOrFileMention)
    }

    /// 交互回复里的尾部库存块。它通常长这样:
    /// "现场状态/讲解正文 + 分隔线 + 已完成/产出物/文件路径清单"。
    /// 这里保持通用:不关心材料类型,只识别"完成/交付叙述 + 文件/路径/清单证据"。
    nonisolated static func isInteractionInventoryTail(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if isArtifactInventoryStatus(value) || isLikelyDeliveryInventoryStatus(value) { return true }

        let lower = value.lowercased()
        let hasCompletion = [
            "已完成", "全部完成", "完整交付", "最终交付", "已生成", "已保存",
            "已打开", "已进入", "completed", "completion", "delivered"
        ].contains { lower.contains($0.lowercased()) }
        let hasInventoryEvidence = [
            "产出物", "交付物", "文件", "路径", "清单",
            "artifact", "output", "file", "path",
            ".pptx", ".pdf", ".html", ".htm", ".docx", ".xlsx", ".md", ".txt",
            "`/", "\"/", "/users/"
        ].contains { lower.contains($0.lowercased()) }
        let listLike = [
            "\n1.", "\n2.", "\n3.", "\n- ", "\n•", "|", "**", "✅"
        ].contains { value.contains($0) }
        return hasCompletion && hasInventoryEvidence && listLike
    }

    nonisolated static func latestSubstantiveSpokenLine(after baseline: Int, in lines: [String]) -> String? {
        guard baseline < lines.count else { return nil }
        return lines.dropFirst(baseline)
            .map(cleanSpokenLine)
            .reversed()
            .first { $0.count >= 40 && !isHollowInteractionStatus($0) && !isArtifactInventoryStatus($0) }
    }

    /// 交互型回复如果前半段已经说明现场状态,后半段又追加了“产出物/文件/路径”库存表,
    /// 主聊天气泡应保留现场状态,库存明细留在任务记录/产出物面板。这个裁剪只在交互上下文调用。
    nonisolated static func trimInteractionInventoryTail(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 12 else { return nil }
        let markers = [
            "\n### 产出物", "\n## 产出物", "\n# 产出物",
            "\n### 交付物", "\n## 交付物", "\n# 交付物",
            "\n| 文件 |", "\n| 路径 |",
            "\n### 演示进度", "\n## 演示进度"
        ]
        var hit = markers
            .compactMap({ marker -> String.Index? in value.range(of: marker, options: [.caseInsensitive])?.lowerBound })
            .min()
        if hit == nil {
            let tailCutMarkers = [
                "\n---", "\n***", "\n___",
                "\n**已完成", "\n## 已完成", "\n### 已完成",
                "\n✅ 全部完成", "\n## ✅", "\n### ✅"
            ]
            for marker in tailCutMarkers {
                var searchStart = value.startIndex
                while searchStart < value.endIndex,
                      let range = value.range(
                        of: marker,
                        options: [.caseInsensitive],
                        range: searchStart..<value.endIndex
                      ) {
                    let tail = String(value[range.upperBound...])
                    if isInteractionInventoryTail(tail) {
                        hit = range.lowerBound
                        break
                    }
                    searchStart = range.upperBound
                }
                if hit != nil { break }
            }
        }
        guard let hit else { return nil }
        var headValue = String(value[..<hit])
        if let separator = headValue.range(of: "\n---")?.lowerBound {
            headValue = String(headValue[..<separator])
        }
        if let completion = headValue.range(of: "✅")?.lowerBound {
            headValue = String(headValue[..<completion])
        }
        let head = headValue
            .replacingOccurrences(of: "(?m)^\\s*[-_]{3,}\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+——\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "——\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.count >= 8 else { return nil }
        return head
    }

    nonisolated static func isUsefulInteractionSummary(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 8 else { return false }
        if compact.contains("完整交付") && !compact.contains("已进入") && !compact.contains("等待") && !compact.contains("讲解") {
            return false
        }
        let usefulSignals = ["第一页", "第1页", "第1頁", "第1", "当前", "已进入", "演示状态", "等待", "提问", "讲解", "预览", "全屏"]
        return usefulSignals.contains { compact.contains($0) }
    }

    /// 流式早读只念“人能听懂的内容”。路径、Markdown 表格、产出物库存适合放在屏幕/任务记录里,
    /// 不适合在现场语音里逐字读出。
    nonisolated static func speechSafeStreamText(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return nil }
        let compact = value
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        if compact.hasPrefix("|") || compact.contains("|------|") || compact == "---" { return nil }
        if compact == "已完成:" || compact == "已完成：" || compact == "**已完成:**" || compact == "**已完成：**" {
            return nil
        }
        if trimInteractionInventoryTail(value) != nil { return nil }
        if isArtifactInventoryStatus(value) || isLikelyDeliveryInventoryStatus(value) { return nil }
        if compact.contains("完整交付") { return nil }
        if compact.contains("页面结构") || compact.contains("当前状态") { return nil }
        if compact.contains("全部完成")
            && ["演示", "交付", "产出", "预览"].contains(where: { compact.contains($0) }) {
            return nil
        }
        if compact.contains("已生成")
            && [".pptx", ".pdf", ".html", ".htm", ".docx", ".xlsx", ".md", ".txt"].contains(where: { compact.lowercased().contains($0) }) {
            return nil
        }
        if compact.contains("已在灵枢内打开预览") || compact.contains("打开预览并已进入") {
            return nil
        }
        let lower = value.lowercased()
        let pathOrExtension = [
            "`/", "\"/", ".pptx", ".pdf", ".html", ".htm", ".docx", ".xlsx", ".md", ".txt", ".py", ".json", ".csv"
        ].contains { lower.contains($0) }
        if pathOrExtension && ["产出物", "文件", "路径", "交付物", "artifact", "output"].contains(where: { lower.contains($0.lowercased()) }) {
            return nil
        }
        let structuralHead = [
            "#", "##", "###", "- ✅", "- ⏸", "✅ **", "|"
        ].contains { value.hasPrefix($0) }
        if structuralHead && ["产出物", "演示进度", "文件", "路径"].contains(where: { value.contains($0) }) {
            return nil
        }
        return value
    }

    nonisolated static func cleanSpokenLine(_ text: String) -> String {
        text.replacingOccurrences(of: "^\\[屏显第\\d+页\\]\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func previewableArtifacts(
        in record: LingShuTaskExecutionRecord?,
        preferPaginated: Bool = false
    ) -> [LingShuTaskExecutionArtifact] {
        guard let record else { return [] }
        return record.artifacts
            .filter { FileManager.default.fileExists(atPath: $0.location) }
            .filter { previewExtensions.contains(($0.location as NSString).pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                previewRank(lhs.location, preferPaginated: preferPaginated) < previewRank(rhs.location, preferPaginated: preferPaginated)
            }
    }

    nonisolated static func firstPageNarration(title: String, pageText: String) -> String {
        pageNarration(title: title, pageNumber: 1, totalPages: nil, pageText: pageText)
    }

    nonisolated static func pageNarration(title: String, pageNumber: Int, totalPages: Int?, pageText: String) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactPage = pageText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "；")
        let pageLabel = totalPages.map { "第 \(pageNumber)/\($0) 页" } ?? "第 \(pageNumber) 页"
        if compactPage.isEmpty {
            return cleanTitle.isEmpty
                ? "\(pageLabel)我先根据画面继续讲。"
                : "材料「\(cleanTitle)」\(pageLabel)我先根据画面继续讲。"
        }
        let prefix = cleanTitle.isEmpty ? pageLabel : "「\(cleanTitle)」\(pageLabel)"
        return "\(prefix)主要说明：\(String(compactPage.prefix(180)))"
    }

    nonisolated static func readablePreviewText(for artifact: LingShuTaskExecutionArtifact) -> String {
        let ext = (artifact.location as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm":
            return readableHTMLText(path: artifact.location)
        case "md", "txt":
            guard let raw = try? String(contentsOfFile: artifact.location, encoding: .utf8) else { return "" }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return ""
        }
    }

    private nonisolated static func previewRank(_ path: String, preferPaginated: Bool) -> Int {
        if preferPaginated {
            switch (path as NSString).pathExtension.lowercased() {
            case "pdf": return 0
            case "pptx": return 1
            case "docx", "xlsx": return 2
            case "html", "htm": return 3
            case "md", "txt": return 4
            default: return 5
            }
        }
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return 0
        case "pdf": return 1
        case "pptx": return 2
        case "docx", "xlsx": return 3
        case "md", "txt": return 4
        default: return 5
        }
    }

    private nonisolated static func forbidsManagedInteraction(_ value: String) -> Bool {
        let blockers = ["不要进入", "不要全屏", "不要托管", "不要自主", "只普通预览", "别全屏", "no fullscreen", "no slideshow"]
        return blockers.contains { value.contains($0.lowercased()) }
    }

    private nonisolated static func readableHTMLText(path: String) -> String {
        guard var raw = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        raw = removeHTMLBlocks(raw, tag: "script")
        raw = removeHTMLBlocks(raw, tag: "style")
        raw = raw.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        raw = raw.replacingOccurrences(of: "(?i)</(p|div|section|li|h[1-6]|tr)>", with: "\n", options: .regularExpression)
        raw = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        raw = htmlDecode(raw)
        return raw
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private nonisolated static func removeHTMLBlocks(_ raw: String, tag: String) -> String {
        raw.replacingOccurrences(
            of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>",
            with: "",
            options: .regularExpression
        )
    }

    private nonisolated static func htmlDecode(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
