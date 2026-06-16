import Foundation

/// 断网主动重试 + 可见进度(用户反馈 2026-06-16):断网后**不被动干等** NWPathMonitor,而是像 MySQL 重连那样
/// 按退避主动重试,并在**主对话框**用一条原地更新的状态气泡展示「第 N 次重试 / 下次约 X 秒」;一旦续上,
/// 任务回到「进行中」(看得见在跑),而不是憋到完成才弹结果。NWPathMonitor 链路恢复会立即唤醒重试(重置退避)。
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

            networkRetryAttempt += 1
            updateNetworkRetryBubble("🌐 网络异常中断,已暂停 \(pendingCount) 个任务,正在重试(第 \(networkRetryAttempt) 次)…")

            // 用**轻量网关探针**判网络是否真回来(便宜、快),而不是拿真任务去试(那又慢又会把"重试"和"长程跑"混在一起)。
            if await probeGatewayReachable() {
                // 网络回来了 → 收尾状态气泡进「网络已恢复,继续执行」,再 fire-and-forget 续跑暂停的任务(后台跑到完成)。
                clearNetworkRetryBubble(resumedNotice: true)
                await resumeSuspendedWork()
                break
            }
            let delay = Self.networkRetryBackoff[min(networkRetryAttempt - 1, Self.networkRetryBackoff.count - 1)]
            updateNetworkRetryBubble("🌐 网络仍未恢复,已重试 \(networkRetryAttempt) 次,约 \(delay)s 后再试…")
            await sleepInterruptible(delay)
        }
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

    /// 重连成功:把状态气泡收尾;resumedNotice=true 时另发一条「网络已恢复,继续执行」(会被语音念恢复句)。
    func clearNetworkRetryBubble(resumedNotice: Bool) {
        networkRetryBubbleID = nil
        networkRetryAttempt = 0
        if resumedNotice {
            chatMessages.append(.init(speaker: "灵枢", text: "🔄 网络已恢复,正在接着把任务跑完。", isUser: false))
        }
    }
}
