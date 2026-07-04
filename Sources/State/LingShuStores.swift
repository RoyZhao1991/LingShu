import Combine
import Foundation

/// Chat lane state. It intentionally does not forward changes through `LingShuState.objectWillChange`:
/// streaming bubble deltas should invalidate only the chat list, not the whole app shell or input field.
@MainActor
final class LingShuChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = [
        .init(speaker: "灵枢", text: "我在。你只管说目标，剩下的判断、分派和推进交给我。", isUser: false)
    ] {
        didSet { onMessagesChanged?(messages) }
    }

    @Published var scrollToLatestRequest = 0
    @Published var hasMoreColdHistory = false

    var onMessagesChanged: (([ChatMessage]) -> Void)?
}

/// Input lane state. It owns transient user input artifacts so the chat list can stream independently.
@MainActor
final class LingShuInputStore: ObservableObject {
    @Published var prompt = ""
    @Published var pendingAttachments: [LingShuAttachment] = []
    @Published var detectedInvocationChips: [LingShuInvocationChip] = []
}

/// Runtime lane state. It holds high-level execution indicators that are shared across shell/status views.
@MainActor
final class LingShuRuntimeStore: ObservableObject {
    @Published var missionTitle = "待机中"
    @Published var missionStatus = "我在。能力池已注册，随时待命，等你开口。"
    @Published var coreState: LingShuCoreState = .standby
    @Published var loopPhase: LingShuLoopPhase = .idle
    @Published var runtimePhase: MissionRuntimePhase = .idle
    @Published var isModelReplying = false
    @Published var isModelExecuting = false
    @Published var taskRuntime: TaskRuntimeSnapshot = .idle
}
