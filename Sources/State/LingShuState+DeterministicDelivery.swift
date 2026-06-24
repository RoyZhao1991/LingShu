import Foundation

@MainActor
extension LingShuState {
    /// Pure runtime-tool tasks with fully proven success criteria do not need another subjective LLM review.
    /// This keeps the verifier strict for artifacts, devices, environments, and user-confirmation work.
    func deterministicAcceptanceDeliveryIfReady(
        _ acceptance: LingShuAcceptanceReport,
        codeFiles: [String]
    ) -> (passed: Bool, critique: String)? {
        guard codeFiles.isEmpty,
              LingShuVerifierGate.deterministicAcceptanceCanSkipLLM(acceptance) else {
            return nil
        }
        appendTrace(
            kind: .result,
            actor: "验收",
            title: "确定性成功标准通过·跳过LLM评审",
            detail: "工具/命令型目标已由执行记录证明达成,无需主观评审。"
        )
        return (true, "成功标准已由执行记录确定性证明达成,跳过冗余 LLM 评审。")
    }
}
