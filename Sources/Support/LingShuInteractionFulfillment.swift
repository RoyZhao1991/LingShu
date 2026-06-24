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
        let liveSignals = [
            "开始演示", "全屏演示", "进入演示", "放映", "占屏", "自主模式", "托管模式",
            "替我汇报", "自己汇报", "完整汇报", "现场汇报", "现场答疑", "答辩",
            "路演", "讲解", "讲给", "带我看", "带着我看", "主持", "全自动播放",
            "present", "presentation", "slideshow", "walk me through", "demo"
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

    nonisolated static func isVisiblePresentationControl(_ text: String) -> Bool {
        isContinuePresentationCommand(text) || isNextPageCommand(text) || isPreviousPageCommand(text)
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

    nonisolated static func latestSubstantiveSpokenLine(after baseline: Int, in lines: [String]) -> String? {
        guard baseline < lines.count else { return nil }
        return lines.dropFirst(baseline)
            .map(cleanSpokenLine)
            .reversed()
            .first { $0.count >= 40 && !isHollowInteractionStatus($0) }
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
