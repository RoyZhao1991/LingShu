import Foundation

@MainActor
extension LingShuState {
    func registerSpeechIntent(
        for messageID: UUID,
        request: String,
        source: LingShuDialogueInputSource
    ) {
        let decision = LingShuSpeechIntentPolicy.decision(for: request, source: source)
        if decision == .unspecified {
            speechIntentDecisions.removeValue(forKey: messageID)
        } else {
            speechIntentDecisions[messageID] = decision
        }
    }

    func shouldSpeakReply(messageID: UUID) -> Bool {
        switch speechIntentDecisions[messageID] {
        case .silent:
            return false
        case .speak:
            return true
        case .unspecified, nil:
            return persistentOrLiveSpeechOutputEnabled
        }
    }

    func clearSpeechIntent(for messageID: UUID) {
        speechIntentDecisions.removeValue(forKey: messageID)
    }

    func shouldAllowDirectSpeech(
        request: String? = nil,
        source: LingShuDialogueInputSource = .typed
    ) -> Bool {
        if let request {
            switch LingShuSpeechIntentPolicy.decision(for: request, source: source) {
            case .silent:
                return false
            case .speak:
                return true
            case .unspecified:
                break
            }
        }

        if let executingChatTurnID {
            switch speechIntentDecisions[executingChatTurnID] {
            case .silent:
                return false
            case .speak:
                return true
            case .unspecified, nil:
                break
            }
        }
        if let recordID = currentAgentTurnRecordID,
           let bubbleID = dispatchedTaskBubbles[recordID] {
            switch speechIntentDecisions[bubbleID] {
            case .silent:
                return false
            case .speak:
                return true
            case .unspecified, nil:
                break
            }
        }
        return persistentOrLiveSpeechOutputEnabled
    }

    func markCurrentReplyAsSpoken() {
        if let executingChatTurnID {
            lastSpokenMessageID = executingChatTurnID
            return
        }
        if let recordID = currentAgentTurnRecordID,
           let bubbleID = dispatchedTaskBubbles[recordID] {
            lastSpokenMessageID = bubbleID
        }
    }

    private var persistentOrLiveSpeechOutputEnabled: Bool {
        voiceOutputEnabled
            || isMinimalVoiceMode
            || isVoiceConversationActive
            || isMeetingConversationActive
            || presentationController.isActive
            || previewController.slideshow
    }
}
