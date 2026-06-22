import Foundation

/// **确认气泡 → 可点击选项**(壳层渲染,模型无关)。灵枢是"人"、信息交互靠对话文字;但"要你定"的确认应让你**点击**推进
/// (像 Claude 的允许/拒绝按钮——由壳渲染,不靠模型去调某工具)。本解析把"卡住要你定 + 1./①/1️⃣ 枚举选项"的文本
/// 解析成 `CodexRouteChoicePrompt`(question + options),供对话气泡渲染成按钮。纯逻辑可单测。
enum LingShuChoiceParsing {

    /// 解析文本里的枚举选项;不足 2 个有效选项返回 nil(不是选择题)。
    static func parse(_ text: String) -> CodexRouteChoicePrompt? {
        var questionLines: [String] = []
        var options: [CodexRouteChoiceOption] = []
        var inOptions = false
        for raw in text.components(separatedBy: .newlines) {
            if let content = strippedMarker(raw) {
                inOptions = true
                let (label, detail) = splitLabelDetail(content)
                if !label.isEmpty { options.append(CodexRouteChoiceOption(label: label, detail: detail)) }
            } else if !inOptions {
                questionLines.append(raw)
            }
        }
        guard options.count >= 2 else { return nil }
        // **防"多问题被当成单选项"误渲染(用户实测:5 个确认问题被 flatten 成一个单选卡)**:
        // 若这些"选项"本身大多是**问题**(以 ?/? 结尾),说明这是一张多事项确认清单、不是一道单选题——
        // 返回 nil 不渲染单选卡(那会让人误以为"五选一")。这种应由模型走 ask_form 弹多字段表单(每项各自菜单)。
        let questionLike = options.filter { let l = $0.label.trimmingCharacters(in: .whitespaces); return l.hasSuffix("?") || l.hasSuffix("？") }.count
        if questionLike * 2 >= options.count { return nil }
        // **防"交付报告/说明里的编号清单被误当选择卡"(2026-06-21 用户实测:分账验收报告的 8 条功能渲染成 8 个"选项")**:
        // ① 报告/交付类文本(含 passed/pytest/验收/产出物/试算平衡 等信号)里的编号项是**说明**不是选项;
        // ② 选项标签都很长(描述性,而非"接入/暂不/方案A"这类供选择的短词)=这是清单不是选择题。两者任一命中→不渲染选择卡。
        let reportSignals = ["passed", "failed", "pytest", "验收", "产出物", "试算平衡", "balanced", "新增测试", "总用时", "0 failed"]
        if reportSignals.contains(where: { text.contains($0) }) { return nil }
        let avgLabelLen = options.map(\.label.count).reduce(0, +) / max(1, options.count)
        if avgLabelLen > 14 { return nil }
        // 保留换行(原来 joined(" ") 会把表格/分段压成一行);question 现不在卡片里渲染,但保持其内容良构。
        let q = questionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexRouteChoicePrompt(question: q, options: options)
    }

    /// 去掉行首的枚举标记(数字./)、、:、圆圈①、keycap 1️⃣),返回其后内容;非选项行返回 nil。
    /// 不认普通项目符号(- • *)以免误判正文。
    static func strippedMarker(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let scalars = Array(s.unicodeScalars)
        // keycap emoji(如 1️⃣):前 3 个标量内含组合 keycap U+20E3。
        if let idx = scalars.firstIndex(of: Unicode.Scalar(0x20E3)!), idx <= 2 {
            return String(String.UnicodeScalarView(scalars[(idx + 1)...])).trimmingCharacters(in: .whitespaces)
        }
        // 圆圈数字 ①(U+2460)–⑳(U+2473)。
        if let f = scalars.first, (0x2460...0x2473).contains(f.value) {
            return String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // 1. / 1) / 1、 / 1: (数字 + 分隔符)。
        if let f = s.first, f.isNumber {
            var i = s.startIndex
            while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
            if i < s.endIndex, ".)、:：．".contains(s[i]) {
                let after = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                return after.isEmpty ? nil : after
            }
        }
        return nil
    }

    /// 把"接入 — 说明"拆成 label(简短动作)+ detail(说明)。先去 markdown 粗体。
    static func splitLabelDetail(_ content: String) -> (String, String?) {
        let c = content.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        for sep in ["——", "—", " - ", ":", ":", "(", "("] {
            if let r = c.range(of: sep) {
                let label = String(c[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let detail = String(c[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { return (label, detail.isEmpty ? nil : detail) }
            }
        }
        return (c, nil)
    }
}
