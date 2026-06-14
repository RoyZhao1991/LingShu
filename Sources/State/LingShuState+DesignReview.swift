import Foundation
import PDFKit
import AppKit

/// 过程内设计审计与纠正(自进化 PPT · Phase B)——**不等最终验收**,生成后立刻按 rubric 打分 + 指出问题,
/// 模型据此改 slides.json 重生成,达标再交付。分数落任务记录 `designScore`,供 dreaming(Phase C)进化 DesignKB。
@MainActor
extension LingShuState {

    struct DeckDesignAudit: Sendable {
        var score: Double          // 0–1 总分(逐页均值)
        var perPage: [String]      // 每页一行:"P1: 0.82 <问题/OK>"
        var lowPages: [String]     // 低于阈值的页(需改进)
    }

    /// 审计结果(带诊断):成功打分 / 视觉不可用 / 缺渲染器 / 渲染失败 / VL 未给分。
    /// 失败分支带**真实原因**——不再笼统"审计不可用",让"为什么"可见可诊断。
    enum DeckAuditOutcome: Sendable {
        case scored(DeckDesignAudit)
        case visionUnavailable(String)   // 云端 VL 未配置/不可达,带原因
        case rendererMissing             // 本机缺 LibreOffice
        case renderFailed                // soffice 没渲出 PDF
        case inconclusive                // VL 响应了但一页都没给出分数
    }

    /// 渲染 .pptx→逐页交云端 VL 按 DesignKB rubric 打设计分。各失败分支带原因(供 review_design 如实报错)。
    /// `topic`=本次任务主题,传给 VL 以便判**配图是否切题**(无主题就判不了相关性,只能漏过烂图)。
    func auditDeckDesign(path: String, topic: String = "", maxPages: Int = 10) async -> DeckAuditOutcome {
        guard let vl = cloudPerceptionClient else {
            let hasKey = !(credentialStore.apiKey(forProvider: ModelProviderPreset.dataNetGateway.id) ?? "").isEmpty
            return .visionUnavailable(hasKey
                ? "云端视觉(VL/数据网关)初始化失败:端点不可用。"
                : "云端视觉(VL)未配置:当前主通道是「\(modelProvider)」而非数据网关,且本机未存数据网关 key——看图审版式走的是数据网关 Qwen-VL,需要它的 key。")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        var pdfPath = path
        if ext != "pdf" {
            let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            guard FileManager.default.isExecutableFile(atPath: soffice) else { return .rendererMissing }
            let outDir = (path as NSString).deletingLastPathComponent
            // 独立 UserInstallation 配置,避开与最终验收/用户 soffice 实例的文件锁冲突。
            let profile = "file:///tmp/lingshu-soffice-\(UUID().uuidString.prefix(8))"
            _ = await Self.runCapturing(soffice, ["-env:UserInstallation=\(profile)", "--headless", "--convert-to", "pdf", "--outdir", outDir, path], timeout: 120)
            pdfPath = (path as NSString).deletingPathExtension + ".pdf"
        }
        guard FileManager.default.fileExists(atPath: pdfPath),
              let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return .renderFailed }

        let rubric = LingShuDesignKB.rubricText() ?? "层级清晰 / 留白充足 / 无文字重叠或截断 / 有视觉支撑(图片图标图表) / 一页一个核心点 / 配色统一克制"
        var scores: [Double] = []
        var perPage: [String] = []
        var low: [String] = []
        for idx in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: idx), let b64 = Self.pdfPageBase64PNG(page) else { continue }
            let topicLine = topic.isEmpty ? "" : "本页属于一份关于「\(topic.prefix(40))」的 PPT。"
            let prompt = "你是资深 PPT 设计评审。\(topicLine)按这份清单评这一页的**设计质量(不是内容对错)**:\n\(rubric)\n**重点逐项查并指出**:① 标题/正文是否触边、压到图片、被截断或溢出 ② 配图是否切题(与主题无关的通用照片/会议照/水印图必须指出「配图不相关」) ③ 是否纯文字无视觉、留白失衡、文字重叠。\n**第一行必须是** `score=<0到1之间的两位小数>`,第二行 `issue=<一句话最该改的问题;没问题写 OK>`。"
            guard let result = try? await vl.analyzeImage(imageBase64: b64, prompt: prompt, includeGrounding: false), result.success else { continue }
            // 优先用 VL 给的数字分;此网关 VL 多返回**描述性评估**,故退而从描述里的"版式问题关键词"推分。
            let resolved: (score: Double, issue: String)
            if let s = Self.parseDesignScore(result.semanticSuggestions) {
                resolved = (s, Self.parseDesignIssue(result.semanticSuggestions))
            } else if let derived = Self.deriveDesignScoreFromDescription(result.semanticSuggestions) {
                resolved = derived
            } else { continue }
            let note = "P\(idx + 1): \(String(format: "%.2f", resolved.score)) \(resolved.issue)"
            scores.append(resolved.score)
            perPage.append(note)
            if resolved.score < 0.7 { low.append(note) }
        }
        guard !scores.isEmpty else { return .inconclusive }
        return .scored(DeckDesignAudit(score: scores.reduce(0, +) / Double(scores.count), perPage: perPage, lowPages: low))
    }

    /// review_design 工具:过程内自审。生成 .pptx 后调用→拿设计分+逐页问题→低分就改 slides.json 重生成再审。
    func reviewDesignTool(recordIDProvider: @escaping @MainActor @Sendable () -> String?) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "review_design",
            description: "对刚生成的 PPT/视觉文件做**设计质量审计**(渲染→看图按 rubric 打 0–1 分 + 逐页问题)。**生成 .pptx 后必须先自审**:分 < 0.7 或有版式硬伤(重叠/截断/纯文字)就改 slides.json 重生成再 review,达标(≥0.7)再交付——别等最终验收才发现。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"要审计的 .pptx/.pdf 绝对路径\"}},\"required\":[\"path\"]}"
        ) { [weak self] argsJSON in
            let path = Self.jsonField(argsJSON, "path") ?? argsJSON
            guard let self else { return "执行环境不可用" }
            // 取本任务主题传给 VL,让它能判"配图是否切题"。
            let topic = await MainActor.run { [weak self] () -> String in
                guard let self, let rid = recordIDProvider() else { return "" }
                return self.taskExecutionRecords.first { $0.id == rid }?.prompt ?? ""
            }
            switch await self.auditDeckDesign(path: path, topic: topic) {
            case .scored(let audit):
                await MainActor.run { [weak self] in self?.recordDesignScore(audit.score, issues: audit.lowPages, recordID: recordIDProvider()) }
                let verdict = audit.score >= 0.7 ? "达标 ✅,可交付" : "未达标 ⚠️,需修正后重生成"
                var out = "设计质量分 \(String(format: "%.2f", audit.score))(\(verdict))\n逐页:\n\(audit.perPage.joined(separator: "\n"))"
                if !audit.lowPages.isEmpty {
                    out += "\n\n重点修这些页(改 slides.json 对应页的 layout/内容/配图后,重新跑生成器再 review_design):\n\(audit.lowPages.joined(separator: "\n"))"
                }
                return out
            case .visionUnavailable(let reason):
                await MainActor.run { [weak self] in self?.flagDesignAuditUnavailable(reason, recordID: recordIDProvider()) }
                return "⚠️ 设计自审没跑成(不是通过、是没跑):\(reason)\n→ 处理:到「配置」填数据网关(VL)的 key,或把主通道切到数据网关;在此之前我无法看图给设计分。本次先确保产出物已落盘、版式无明显硬伤再交付。"
            case .rendererMissing:
                await MainActor.run { [weak self] in self?.flagDesignAuditUnavailable("本机缺渲染器 LibreOffice(/Applications/LibreOffice.app)——看图审版式需要它把 .pptx 渲成 PDF。", recordID: recordIDProvider()) }
                return "⚠️ 设计自审没跑成:本机缺 LibreOffice,无法把 .pptx 渲成图来审。装上 LibreOffice 即可;本次先人工确认版式。"
            case .renderFailed:
                await MainActor.run { [weak self] in self?.flagDesignAuditUnavailable("soffice 渲染 .pptx→PDF 失败(没产出 PDF),可能文件损坏或 soffice 被占用。", recordID: recordIDProvider()) }
                return "⚠️ 设计自审没跑成:渲染 .pptx→PDF 失败(soffice 没出 PDF)。检查文件是否损坏或重试;本次先人工确认版式。"
            case .inconclusive:
                return "设计自审已看图,但 VL 未给出量化分(可能它只回了描述)。请据描述人工判断版式有无硬伤后交付——不强制重做。"
            }
        }
    }

    /// 把设计分 + 失败点落进任务记录(+一条审计消息),供窗口展示 + dreaming 读取进化(含失败点)。
    func recordDesignScore(_ score: Double, issues: [String], recordID: String?) {
        guard let recordID, let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[index].designScore = score
        taskExecutionRecords[index].designIssues = issues
        let issueText = issues.isEmpty ? "" : "\n待改进:\n" + issues.joined(separator: "\n")
        appendTaskRecordMessage(recordID, actor: "设计审计", role: "质量分", kind: .review, text: "设计质量分 \(String(format: "%.2f", score))(过程内自审)\(issueText)")
        appendTrace(kind: score >= 0.7 ? .result : .warning, actor: "设计审计", title: "设计质量分 \(String(format: "%.2f", score))", detail: score >= 0.7 ? "达标" : "未达标,需修正")
        persistTaskExecutionRecords()
    }

    /// 设计自审**没能跑起来**:把真实原因落进记录 + 醒目告警轨迹(运行态可见),不再静默"不可用"。
    func flagDesignAuditUnavailable(_ reason: String, recordID: String?) {
        appendTrace(kind: .warning, actor: "设计审计", title: "自审未运行(非通过)", detail: reason)
        if let recordID, let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) {
            appendTaskRecordMessage(recordID, actor: "设计审计", role: "未运行", kind: .warning, text: "设计自审没跑成:\(reason)")
            persistTaskExecutionRecords()
        }
    }

    /// 从 VL 回复抽 0–1 设计分。认 score=/分=、`X/10`、`N%`、`N分`(>1 视百分制)、再退首个 0–1 小数。
    /// **抽不到数字返回 nil**(调用方据此判定"未打分",不强制重做)——别再用 0.6 假失败逼空转。
    nonisolated static func parseDesignScore(_ text: String) -> Double? {
        func firstGroup(_ pattern: String) -> Double? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return Double(text[r])
        }
        if let v = firstGroup("score\\s*=\\s*([01](?:\\.\\d+)?)"), v >= 0, v <= 1 { return v }
        if let v = firstGroup("分[数值]?\\s*[=:：]\\s*([01](?:\\.\\d+)?)"), v >= 0, v <= 1 { return v }
        if let v = firstGroup("([0-9]+(?:\\.\\d+)?)\\s*/\\s*10"), v >= 0, v <= 10 { return v / 10 }
        if let v = firstGroup("([0-9]{1,3})\\s*[%分]"), v >= 0, v <= 100 { return v / 100 }
        if let v = firstGroup("\\b(0\\.\\d+|1\\.0|1|0)\\b"), v >= 0, v <= 1 { return v }
        return nil
    }

    /// VL 没给数字分时,从它的**描述**里推一个设计分:命中版式问题关键词→0.5(并带问题),否则视为达标 0.8。
    /// 让"描述型"VL(本网关 Qwen-VL 多返回 summary/tags)也能驱动过程内审计,而不是一律 inconclusive。
    nonisolated static func deriveDesignScoreFromDescription(_ text: String) -> (score: Double, issue: String)? {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard clean.count >= 4 else { return nil }   // 真没内容才放弃
        let problems = ["重叠", "截断", "被切", "溢出", "触边", "压到", "贴边", "超出", "出血", "空白过多", "拥挤", "模糊",
                        "错位", "歪", "对不齐", "看不清", "遮挡", "杂乱", "纯文字", "无视觉",
                        "不相关", "无关", "不切题", "关系不大", "通用照片", "会议照", "水印",
                        "overlap", "truncat", "cut off", "cut-off", "cluttered", "overflow", "misalign", "blurr", "irrelevant", "unrelated", "watermark"]
        let lower = clean.lowercased()
        let hits = problems.filter { lower.contains($0.lowercased()) }
        if hits.isEmpty { return (0.8, "未见明显版式问题") }
        return (0.5, "VL 指出:" + hits.prefix(3).joined(separator: "/") + " — " + clean.prefix(50))
    }

    /// 抽问题描述(取 `|` 后面的话,缺省整段截断)。
    nonisolated static func parseDesignIssue(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let bar = clean.range(of: "|") {
            return String(clean[bar.upperBound...]).trimmingCharacters(in: .whitespaces).prefix(80).description
        }
        return String(clean.prefix(80))
    }
}
