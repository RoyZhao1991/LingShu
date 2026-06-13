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
        if sessionShellAlwaysAllowed { return .allowAlways }
        if clarificationCenter.isNonInteractive() { return .deny }

        return await withCheckedContinuation { (continuation: CheckedContinuation<LingShuShellApprovalDecision, Never>) in
            pendingShellApproval = LingShuPendingShellApproval(
                command: command,
                workingDirectory: workingDirectory,
                taskRecordID: taskRecordID,
                resume: { decision in continuation.resume(returning: decision) }
            )
        }
    }

    /// 用户在授权弹窗上点选：清挂起、按需置「会话始终允许」、回传决定恢复协程。
    func resolveShellApproval(_ decision: LingShuShellApprovalDecision) {
        guard let pending = pendingShellApproval else { return }
        pendingShellApproval = nil
        if decision == .allowAlways { sessionShellAlwaysAllowed = true }
        switch decision {
        case .allowOnce:   logEvent("用户授权执行系统命令（本次允许）")
        case .allowAlways: logEvent("用户授权执行系统命令（本次会话完全授权）")
        case .deny:        logEvent("用户拒绝执行系统命令")
        }
        pending.resume(decision)
    }
}
