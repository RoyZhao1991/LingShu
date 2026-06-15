import Foundation

/// 系统命令授权决定（高风险动作人工确认）。
enum LingShuShellApprovalDecision {
    case allowOnce       // 本次允许：只放行这一条命令
    case allowAlways     // 完全授权：本次会话后续 run_command 不再询问
    case deny            // 拒绝：命令不执行
}

/// 待授权的系统命令上下文：弹窗据此呈现命令、目录，用户点选后经 `resume` 回传决定。
struct LingShuPendingShellApproval: Identifiable {
    let id = UUID()
    let command: String
    let workingDirectory: String
    let taskRecordID: String?
    /// 自发现 skill 风险审给出的风险点(命中隔离脚本时填,弹窗醒目展示供用户裁决);常规命令为空。
    var riskNotes: [String] = []
    /// 用户点选后回传决定（恢复挂起的工具执行协程）。只会被消费一次。
    let resume: (LingShuShellApprovalDecision) -> Void
}

@MainActor
extension LingShuState {
    /// 请求执行系统命令的授权：弹中文授权框并挂起等待用户点选。
    ///
    /// - 已选「完全授权」→ 直接放行，不再弹。
    /// - 非交互场景（自主 / 无头 / 定时）→ 不打扰用户，按安全默认「拒绝」，保持无人值守不卡死。
    /// - 否则弹窗并 `await` 用户决定。
    func requestShellApproval(command: String, workingDirectory: String, taskRecordID: String?) async -> LingShuShellApprovalDecision {
        // 自发现高风险脚本首次运行:即使会话已"完全授权"也强制弹一次,把风险点摆给用户裁决(供应链红线)。
        let quarantine = quarantinedScriptHit(in: command)
        if quarantine == nil, sessionShellAlwaysAllowed { return .allowAlways }
        if clarificationCenter.isNonInteractive() { return .deny }   // 无人值守:风险脚本同样安全拒绝

        return await withCheckedContinuation { (continuation: CheckedContinuation<LingShuShellApprovalDecision, Never>) in
            pendingShellApproval = LingShuPendingShellApproval(
                command: command,
                workingDirectory: workingDirectory,
                taskRecordID: taskRecordID,
                riskNotes: quarantine?.notes ?? [],
                resume: { decision in continuation.resume(returning: decision) }
            )
        }
    }

    /// 命令是否引用了某个被隔离(高风险待首次审批)的 skill 脚本;命中返回其 skillID + 风险点。
    private func quarantinedScriptHit(in command: String) -> (skillID: String, notes: [String])? {
        for (path, q) in quarantinedScriptPaths where command.contains(path) {
            return (q.skillID, q.notes)
        }
        return nil
    }

    /// 用户在授权弹窗上点选：清挂起、按需置「会话始终允许」、回传决定恢复协程。
    func resolveShellApproval(_ decision: LingShuShellApprovalDecision) {
        guard let pending = pendingShellApproval else { return }
        pendingShellApproval = nil
        if decision == .allowAlways { sessionShellAlwaysAllowed = true }
        // 隔离脚本经用户首次审批(allowOnce/allowAlways)→ 解除隔离,此后走常规审批,不再强制。
        if decision != .deny, let q = quarantinedScriptPaths.first(where: { pending.command.contains($0.key) }) {
            LingShuSkillAcquisition.clearQuarantine(skillID: q.value.skillID)
            quarantinedScriptPaths.removeValue(forKey: q.key)
            logEvent("自发现高风险 skill 脚本经用户首次审批,解除隔离:\(q.value.skillID)")
        }
        switch decision {
        case .allowOnce:   logEvent("用户授权执行系统命令（本次允许）")
        case .allowAlways: logEvent("用户授权执行系统命令（本次会话完全授权）")
        case .deny:        logEvent("用户拒绝执行系统命令")
        }
        pending.resume(decision)
    }
}
