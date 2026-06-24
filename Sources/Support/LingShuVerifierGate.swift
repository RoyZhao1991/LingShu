import Foundation

/// 验收门「贵 LLM 评审」的按交付物类型 gate(差距2·薄基线,2026-06-21)。
///
/// 铁律:**确定性门(测试跑绿/运行不崩/产出物存在)一律不省**——省的只是那次**贵的 LLM 自评**。
/// 判据(纯逻辑,通用、零定制):
/// - **纯代码交付**(有可测源码、且无主观交付物 PPT/文档):确定性代码门已**权威定正确性**——
///   过 → 直接通过、**跳过 LLM**(冗余 + 慢);不过 → 直接按确定性门失败反馈返工、**也跳过 LLM**(失败原因已确定)。
/// - **主观交付物**(PPT/文档/网页…无确定性门)或**代码+主观混合**:必须跑 LLM 评审(事实/版式/完整性是主观维度)。
///
/// 收益:绝大多数编码任务往返**省一次贵调用 + 一次模型往返延迟**(差距2/差距7),且正确性不打折(确定性门照跑)。
enum LingShuVerifierGate {

    /// 决策三态。
    enum Decision: Equatable {
        case skipPassedByDeterministicGate   // 纯代码 + 确定性门过 → 通过,跳过 LLM
        case skipFailedByDeterministicGate   // 纯代码 + 确定性门不过 → 返工,跳过 LLM(失败原因确定)
        case runLLMReview                    // 主观/混合交付 → 跑 LLM 评审
    }

    /// 主观交付物扩展名(会被验收门做正文事实核查 + 版式视觉评审的类型)。
    static let subjectiveExtensions: Set<String> = ["pptx", "docx", "xlsx", "pdf", "html", "htm", "md", "csv", "txt"]

    /// 给定本回合真实落盘文件,判断是否含主观交付物。
    static func hasSubjectiveArtifact(realFilePaths: [String]) -> Bool {
        realFilePaths.contains { subjectiveExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// **代码确定性门(2026-06-21·用户校准)**:**构建成功本身不算达标**(用户定调:"不是构建即成功")。
    /// 必须 ① **跑测试到全绿**(testsGreen)② **运行起来不崩**(!runCrashed)③ **真跑出可见结果**(ranWithVisibleOutput——
    /// 不是"编译通过、无输出、退出码 0"那种空跑)。三者齐 = 达标;缺任一不达标,返工到真把它跑起来、产出能看到的结果。
    /// 这比"必须有单测"更对——要的是**看到它真的运行 + 真的产出结果**,而不是脚手架编译过就收。零关键词、纯看证据。
    static func codeDeterministicGatePasses(hasCodeFiles: Bool, testsGreen: Bool, ranWithVisibleOutput: Bool, runCrashed: Bool) -> Bool {
        if !hasCodeFiles { return true }
        return testsGreen && !runCrashed && ranWithVisibleOutput
    }

    /// 核心决策。`codeFileCount`=可测源码文件数;`hasSubjectiveArtifact`=是否含 PPT/文档等主观交付物;
    /// `codeGatePassed`=确定性代码门(见 `codeDeterministicGatePasses`)是否通过。
    static func decide(codeFileCount: Int, hasSubjectiveArtifact: Bool, codeGatePassed: Bool) -> Decision {
        let pureCode = codeFileCount > 0 && !hasSubjectiveArtifact
        guard pureCode else { return .runLLMReview }
        return codeGatePassed ? .skipPassedByDeterministicGate : .skipFailedByDeterministicGate
    }

    /// 工具/命令型目标的 P3 短路:如果成功标准已经全部由执行记录确定性证明达成,
    /// 且没有文件/内容质量/设备效果这类主观或外部状态标准,就不再调用 LLM 评审官反复挑话术。
    ///
    /// 这不是降低验收,而是把「事实已证明」与「主观交付物质量」分层:
    /// - command_succeeds 全部 met → 可直接通过;
    /// - file_exists / content_quality / device / environment / user_confirmation → 仍需后续评审或用户/设备回读。
    static func deterministicAcceptanceCanSkipLLM(_ report: LingShuAcceptanceReport) -> Bool {
        guard !report.isEmpty else { return false }
        guard report.verdicts.allSatisfy({ $0.status == .met }) else { return false }
        return report.verdicts.allSatisfy { $0.kind == .commandSucceeds }
    }

    /// 独立评审官有时会返回“评审器未返回有效意见/缺少证据”这类**评审链路自身的失败文本**。
    /// 这不是对交付物的具体审查意见,不能当作 maker 的返工需求无限回灌;否则会出现“修正评审器失败提示”
    /// 的伪返工循环。这里只识别协议/链路层的无效意见,真实的 PASS/FAIL 统计或明确结论仍按正常评审处理。
    static func isNonActionableReviewCritique(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let verdict = LingShuChecklistVerdict.parse(trimmed)
        if verdict.declaredPass || verdict.passedCount > 0 || verdict.failedCount > 0 {
            return false
        }

        let normalized = trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
        let protocolFailurePhrases = [
            "评审器未返回有效意见",
            "未返回有效意见",
            "没有返回有效意见",
            "缺少可核验的确定性证据",
            "未返回可执行意见",
            "noactionablecritique",
            "novalidcritique",
            "invalidreview",
            "reviewerfailed"
        ]
        if protocolFailurePhrases.contains(where: { normalized.contains($0.lowercased()) }) {
            return true
        }

        // 人机输入信封/授权信封泄漏到回复区时,也不是交付物审查意见。
        if normalized.contains("lingshu_human_input") || normalized.contains("human_input") {
            return true
        }

        return false
    }

    /// 当评审输出无效时,是否允许宿主侧确定性证据接管。
    /// 只在代码门干净、没有确定性失败,且至少有一种真实证据(文件/动作/已达成成功标准)时放行;
    /// 纯口头声称、纯用户确认/设备效果这类不可核验目标不会被误放行。
    static func hostDeterministicEvidenceCanReplaceInvalidReview(
        codeEvidenceClean: Bool,
        realFiles: [String],
        hadAction: Bool,
        acceptance: LingShuAcceptanceReport
    ) -> Bool {
        guard codeEvidenceClean, !acceptance.hasDeterministicFailure else { return false }
        return !realFiles.isEmpty || hadAction || !acceptance.deterministicallyMet.isEmpty
    }
}
