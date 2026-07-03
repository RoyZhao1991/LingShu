import Foundation

/// 模型通道主动重试 + 可见进度:网络断开、超时、限流、5xx 都属于“基础设施暂停”,
/// 但不能统称为断网。这里按退避主动重试,并在**主对话框**用一条原地更新的状态气泡展示
///「第 N 次重试 / 下次约 X 秒」;一旦续上,任务回到「进行中」。
@MainActor
extension LingShuState {

    /// 退避序列(秒):前几次密,之后封顶 60s。
    private static let networkRetryBackoff = [5, 8, 13, 21, 34, 60]

    /// 有任务因断网暂停时启动主动重试循环(幂等)。
    func startNetworkRetryLoopIfNeeded() {
        guard networkRetryTask == nil else { return }
        networkRetryAttempt = 0
        networkRetryTask = Task { @MainActor [weak self] in
            await self?.runNetworkRetryLoop()
            self?.networkRetryTask = nil
        }
    }

    /// NWPathMonitor 检测到链路恢复:唤醒重试循环立即再试(重置退避到最快),并确保循环在跑。
    func triggerImmediateNetworkRetry() {
        networkRetryKick = true
        networkRetryAttempt = 0
        startNetworkRetryLoopIfNeeded()
    }

    private func runNetworkRetryLoop() async {
        while !Task.isCancelled {
            let suspended = await agentOrchestrator.suspendedIDs()
            let pendingCount = suspended.count + (suspendedMainTurn != nil ? 1 : 0) + (suspendedAutonomousRecordID != nil ? 1 : 0)
            guard pendingCount > 0 else { break }   // 没有待重连的了 → 退出循环

            let reason = await currentSuspendedInfrastructureReason(suspendedIDs: suspended)
            networkRetryAttempt += 1
            updateNetworkRetryBubble(LingShuModelServiceFailure.retryingText(for: reason ?? "", pendingCount: pendingCount, attempt: networkRetryAttempt))

            // 网络不可达时用轻量探针避免拿真任务空转；服务端 busy/限流/超时则按退避后直接续跑一次,
            // 由真实模型调用判定是否恢复。这样不会把 503/限流误判成“网络已恢复”。
            let failure = reason.flatMap(LingShuModelServiceFailure.decodeReason)
            let canTryNow: Bool
            if failure?.kind == .network || failure == nil {
                canTryNow = await probeGatewayReachable()
            } else {
                canTryNow = true
            }
            if canTryNow {
                clearNetworkRetryBubble(resumedNotice: true, reason: reason)
                await resumeSuspendedWork()
                break
            }
            let delay = Self.networkRetryBackoff[min(networkRetryAttempt - 1, Self.networkRetryBackoff.count - 1)]
            updateNetworkRetryBubble(LingShuModelServiceFailure.stillUnavailableText(for: reason ?? "", attempt: networkRetryAttempt, delay: delay))
            await sleepInterruptible(delay)
        }
    }

    private func currentSuspendedInfrastructureReason(suspendedIDs: [String]) async -> String? {
        if let reason = suspendedMainReason { return reason }
        if let reason = suspendedAutonomousReason { return reason }
        for id in suspendedIDs {
            if let reason = await agentOrchestrator.suspendedReason(id: id) { return reason }
        }
        return nil
    }

    /// 轻量探针:对模型网关发个短超时请求,拿到**任意 HTTP 响应**即视为可达(连接失败=不可达)。
    /// 比"拿真任务去试连接"便宜得多,且把"网络是否回来"与"任务长程跑"解耦。
    func probeGatewayReachable() async -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// 可被 NWPathMonitor 提前唤醒的睡眠(每秒查一次 kick)。ignoreKick=true 用于 settle 等待(不被唤醒打断)。
    private func sleepInterruptible(_ seconds: Int, ignoreKick: Bool = false) async {
        var elapsed = 0
        while elapsed < seconds, !Task.isCancelled {
            if !ignoreKick, networkRetryKick { networkRetryKick = false; return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            elapsed += 1
        }
    }

    /// 原地更新主对话框的网络状态气泡(没有就建一条,有就改文本——不刷屏)。
    func updateNetworkRetryBubble(_ text: String) {
        if let id = networkRetryBubbleID, let idx = chatMessages.firstIndex(where: { $0.id == id }) {
            chatMessages[idx].text = text
        } else {
            let bubble = ChatMessage(speaker: "灵枢", text: text, isUser: false)
            networkRetryBubbleID = bubble.id
            chatMessages.append(bubble)
        }
        missionStatus = text.replacingOccurrences(of: "🌐 ", with: "")
    }

    /// 恢复成功:把状态气泡收尾;resumedNotice=true 时另发一条恢复提示(会被语音念恢复句)。
    func clearNetworkRetryBubble(resumedNotice: Bool, reason: String? = nil) {
        networkRetryBubbleID = nil
        networkRetryAttempt = 0
        if resumedNotice {
            chatMessages.append(.init(speaker: "灵枢", text: "🔄 \(LingShuModelServiceFailure.resumedText(for: reason))", isUser: false))
        }
    }
}
