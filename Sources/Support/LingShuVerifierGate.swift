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
}
