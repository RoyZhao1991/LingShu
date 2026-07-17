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
    /// - 已选「完全授权」→ 直接放行，不再弹（`forceConfirm` / 隔离脚本除外）。
    /// - `forceConfirm`(删/改系统级敏感文件)→ 即使「完整授权」也强制弹一次,把风险摆给用户裁决(计划 §1 红线)。
    /// - 非交互场景（自主 / 无头 / 定时）→ 不打扰用户，按安全默认「拒绝」，保持无人值守不卡死。
    /// - 否则弹窗并 `await` 用户决定。
    func requestShellApproval(
        command: String,
        workingDirectory: String,
        taskRecordID: String?,
        forceConfirm: Bool = false
    ) async -> LingShuShellApprovalDecision {
        // 自发现高风险脚本首次运行:即使会话已"完全授权"也强制弹一次,把风险点摆给用户裁决(供应链红线)。
        let quarantine = quarantinedScriptHit(in: command)
        if quarantine == nil {
            // 系统级敏感命令在开发全权下放行,但留醒目审计(发布版会强制确认)。
            if developmentPhaseFullAccess, forceConfirm {
                logEvent("⚠️ [开发全权] 自动放行系统级敏感命令(发布版会强制确认):\(String(command.prefix(140)))")
            }
            // **SafetyKernel:经统一权限矩阵裁决**(dev-full override / 风险级 / 运行模式 / 持久授权收口到一处)。
            // 非 quarantine 命令的自动放行/拒绝都由它定;返回 nil 才落到下面的交互弹窗。
            if let auto = Self.shellApprovalDecision(
                forceConfirm: forceConfirm,
                devFullAccess: developmentPhaseFullAccess,
                sessionAlwaysAllowed: sessionShellAlwaysAllowed,
                nonInteractive: clarificationCenter.isNonInteractive()
            ) {
                return auto
            }
        } else if clarificationCenter.isNonInteractive() {
            return .deny   // 无人值守下的未审脚本:安全拒绝(供应链红线)
        }

        var notes = quarantine?.notes ?? []
        if forceConfirm { notes.insert("此命令会删除或修改系统级敏感文件(/System、/usr、/etc、内核扩展等),即使完整授权也需你确认。", at: 0) }

        return await withCheckedContinuation { (continuation: CheckedContinuation<LingShuShellApprovalDecision, Never>) in
            pendingShellApproval = LingShuPendingShellApproval(
                command: command,
                workingDirectory: workingDirectory,
                taskRecordID: taskRecordID,
                riskNotes: notes,
                resume: { decision in continuation.resume(returning: decision) }
            )
        }
    }

    /// **SafetyKernel·系统命令裁决收口到统一权限矩阵(纯函数,可测,2026-06-22)**:
    /// 把分散的 dev-full / sessionAlways / 非交互 / 风险级判断收敛到 `LingShuPermissionMatrix.decide`——单一真相。
    /// 返回 `nil` = 需交互弹窗(矩阵判 askUser 且有人在);非 nil = 自动裁决(放行/拒绝)。
    /// **dev-full 保留为显式开发者 override**(用户拍板的 knob,不经矩阵自动放行;forceConfirm 由调用方留审计日志)。
    /// 其余全部走矩阵:domain=.terminal,risk=forceConfirm?.critical:.medium,mode=非交互?.autonomous:.standard,
    /// durablyAllowed=sessionAlways。红线由矩阵硬保证(critical 不自动放行、autonomous 下 critical 直拒)。
    /// 行为与改造前逐项等价(见 ShellApprovalKernelTests 的真值表),仅把判断收口、便于其余资源域后续接同一矩阵。
    nonisolated static func shellApprovalDecision(
        forceConfirm: Bool, devFullAccess: Bool, sessionAlwaysAllowed: Bool, nonInteractive: Bool
    ) -> LingShuShellApprovalDecision? {
        if devFullAccess { return .allowAlways }   // 开发者 override(保留现有行为)
        let verdict = LingShuPermissionMatrix.decide(
            domain: .terminal,
            risk: forceConfirm ? .critical : .medium,
            mode: nonInteractive ? .autonomous : .standard,
            durablyAllowed: sessionAlwaysAllowed
        )
        switch verdict {
        case .allow:   return .allowAlways
        case .deny:    return .deny
        case .askUser: return nonInteractive ? .deny : nil   // 无人可问 → 安全拒;有人 → 弹窗(nil)
        }
    }

    /// 命令是否引用了某个被隔离(高风险待首次审批)的 skill 脚本;命中返回其 skillID + 风险点。
    private func quarantinedScriptHit(in command: String) -> (skillID: String, notes: [String])? {
        for (path, q) in quarantinedScriptPaths where command.contains(path) {
            return (q.skillID, q.notes)
        }
        return nil
    }

    /// 开发阶段全权默认值:UserDefaults 显式覆盖优先,否则 DEBUG 构建开(开发期)、Release 关(发布后人工授权)。
    nonisolated static func loadDevFullAccessDefault() -> Bool {
        if let v = UserDefaults.standard.object(forKey: "lingshu.devFullAccess") as? Bool { return v }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 切换开发阶段全权(持久化)。发布上线前置 false 即恢复"每次人工授权"。
    func setDevelopmentPhaseFullAccess(_ on: Bool) {
        developmentPhaseFullAccess = on
        UserDefaults.standard.set(on, forKey: "lingshu.devFullAccess")
        logEvent(on ? "已开启开发阶段全权(系统授权门直接放行)" : "已关闭开发阶段全权(恢复人工授权)")
    }

    /// 输入坞、设置页和授权弹窗统一走这一档；切回沙箱会立即撤销会话级 shell 预授权。
    func setExecutionPermissionMode(_ mode: LingShuExecutionPermissionMode) {
        guard executionPermissionMode != mode || sessionShellAlwaysAllowed != (mode == .fullAccess) else { return }
        executionPermissionMode = mode
        sessionShellAlwaysAllowed = mode == .fullAccess
        logEvent(mode == .fullAccess ? "执行权限切换为完整权限" : "执行权限切换为沙箱权限")
    }

    /// 用户在授权弹窗上点选：清挂起、按需置「会话始终允许」、回传决定恢复协程。
    func resolveShellApproval(_ decision: LingShuShellApprovalDecision) {
        guard let pending = pendingShellApproval else { return }
        pendingShellApproval = nil
        if decision == .allowAlways { setExecutionPermissionMode(.fullAccess) }
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
