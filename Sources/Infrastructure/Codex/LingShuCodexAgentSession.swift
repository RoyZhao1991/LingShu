import Foundation

/// 步骤2·把 Codex CLI 包成一个 `LingShuAgentSessioning`,让编排器**像驱动本地脑一样统一驱动它**
/// (并发上限 / 取消 / 账本 / 验收 全部免费继承)。这正是「Codex 出脑池、当一条可委托的外设/四肢」的执行壳。
///
/// Codex 是「一次性整任务」的 agent:`send`/`resume` 各跑一次 `codex exec`(resume 带服务端会话 id 续);
/// `continueLoop` 无续(返回上次完成结果);不支持中途回灌纠正(`injectCorrection` 恒 false)。
/// 阻塞调用放到 GCD 后台线程,避免占用 Swift 协作线程池;取消经 `CodexExecutionHandle` 透传到子进程。
actor LingShuCodexAgentSession: LingShuAgentSessioning {
    private let cliPath: String
    private let modelName: String
    private let workingDirectory: String
    private let permissionMode: CodexPermissionMode
    private let timeout: TimeInterval
    private let fastMode: Bool

    private var sink: (@Sendable (String) async -> Void)?
    private var sessionID: String?          // codex 服务端会话 id,供 resume
    private var lastReply: String?
    private(set) var turnsUsed: Int = 0
    private(set) var messages: [LingShuAgentMessage] = []
    let toolInvocations: [String] = []      // Codex 内部工具不对外可见
    var isBlocked: Bool { false }           // Codex 不向外暴露中途阻塞;需输入时它内部自理或失败

    init(cliPath: String, modelName: String, workingDirectory: String,
         permissionMode: CodexPermissionMode, timeout: TimeInterval, fastMode: Bool) {
        self.cliPath = cliPath
        self.modelName = modelName
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.timeout = timeout
        self.fastMode = fastMode
    }

    func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) { self.sink = sink }

    func send(_ userText: String) async -> LingShuAgentRunResult { await run(prompt: userText, resume: false) }
    func resume(_ answer: String) async -> LingShuAgentRunResult { await run(prompt: answer, resume: true) }

    func continueLoop() async -> LingShuAgentRunResult {
        // codex exec 是一次性整任务,没有「继续下一回合」。有上次结果就返回,否则视作需重派。
        if let lastReply { return .completed(text: lastReply) }
        return .interrupted(reason: "Codex 任务尚未开始或执行环境已释放,需重新派发。")
    }

    func injectCorrection(_ text: String) -> Bool { false }   // 外部 agent 不支持中途回灌纠正
    func injectBriefing(_ text: String) {}

    private func run(prompt: String, resume: Bool) async -> LingShuAgentRunResult {
        turnsUsed += 1
        messages.append(.init(role: .user, content: prompt))

        let resumeID = resume ? sessionID : nil
        let handle = CodexExecutionHandle()
        // execReply 在子线程同步回调 sessionRegistrar;用 Sendable 盒子接住,跑完回 actor 再落库。
        final class IDBox: @unchecked Sendable { var id: String? }
        let box = IDBox()

        let cliPath = self.cliPath, modelName = self.modelName, workingDirectory = self.workingDirectory
        let permissionMode = self.permissionMode, timeout = self.timeout, fastMode = self.fastMode

        let result: CodexReplyResult = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CodexReplyResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = CodexBridge.execReply(
                        preferredPath: cliPath, modelName: modelName, userPrompt: prompt,
                        workingDirectory: workingDirectory, permissionMode: permissionMode,
                        timeout: timeout, fastMode: fastMode, remoteSessionID: resumeID,
                        cancellation: handle, progress: nil, sessionRegistrar: { box.id = $0 }
                    )
                    cont.resume(returning: r)
                }
            }
        } onCancel: {
            handle.cancel()
        }

        if let id = box.id { sessionID = id }
        switch result {
        case .success(let text):
            lastReply = text
            messages.append(.init(role: .assistant, content: text))
            await sink?(text)                     // Codex 一次性出全文,整段上屏(暂不做 token 级流式)
            return .completed(text: text)
        case .failure(let reason):
            return .interrupted(reason: reason)   // 失败按基础设施中断处理,交由编排器恢复/交还
        }
    }
}
