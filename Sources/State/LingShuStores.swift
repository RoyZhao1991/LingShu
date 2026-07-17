import Combine
import Foundation

/// Chat lane state. It intentionally does not forward changes through `LingShuState.objectWillChange`:
/// streaming bubble deltas should invalidate only the chat list, not the whole app shell or input field.
@MainActor
final class LingShuChatStore: ObservableObject {
    @Published var messages: [ChatMessage] {
        didSet { onMessagesChanged?(messages) }
    }

    @Published var scrollToLatestRequest = 0
    @Published var hasMoreColdHistory = false

    var onMessagesChanged: (([ChatMessage]) -> Void)?

    init(defaults: UserDefaults = .standard) {
        let language = LingShuLanguagePreferenceStore.currentLanguage(in: defaults)
        messages = [
            .init(
                speaker: LingShuLanguagePreferenceStore.assistantDisplayName(for: language),
                text: LingShuLanguagePreferenceStore.initialGreeting(for: language),
                isUser: false
            )
        ]
    }

    func localizePristineGreeting(for language: LingShuVoiceLanguage) {
        guard messages.count == 1,
              let existing = messages.first,
              !existing.isUser,
              LingShuLanguagePreferenceStore.isInitialGreeting(existing.text)
        else { return }

        messages = [
            .init(
                id: existing.id,
                speaker: LingShuLanguagePreferenceStore.assistantDisplayName(for: language),
                text: LingShuLanguagePreferenceStore.initialGreeting(for: language),
                isUser: false,
                createdAt: existing.createdAt
            )
        ]
    }
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
