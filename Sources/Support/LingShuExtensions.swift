import SwiftUI

extension StepState {
    var icon: String {
        switch self {
        case .waiting: "circle"
        case .running: "bolt.fill"
        case .done: "checkmark"
        }
    }

    var color: Color {
        switch self {
        case .waiting: Color.lingFaint
        case .running: .orange
        case .done: .green
        }
    }
}

extension AgentRuntimeMode {
    var icon: String {
        switch self {
        case .dormant: "pause.circle"
        case .planning: "doc.text.magnifyingglass"
        case .working: "bolt.fill"
        case .supervising: "eye"
        case .correcting: "wrench.adjustable"
        case .verifying: "checklist.checked"
        }
    }

    var color: Color {
        switch self {
        case .dormant: Color.lingFaint
        case .planning: .indigo
        case .working: .orange
        case .supervising: .teal
        case .correcting: .red
        case .verifying: .green
        }
    }
}

extension MissionRuntimePhase {
    var icon: String {
        switch self {
        case .idle: "pause.circle"
        case .planning: "doc.text.magnifyingglass"
        case .executing: "cpu"
        case .supervising: "eye"
        case .correcting: "exclamationmark.triangle"
        case .verifying: "checklist.checked"
        case .delivering: "shippingbox"
        }
    }

    var color: Color {
        switch self {
        case .idle: Color.lingFaint
        case .planning: .indigo
        case .executing: .orange
        case .supervising: .teal
        case .correcting: .red
        case .verifying: .green
        case .delivering: .brown
        }
    }
}

extension TaskRuntimeStage {
    var icon: String {
        switch self {
        case .dormant: "pause.circle"
        case .intake: "tray.and.arrow.down"
        case .memory: "brain"
        case .planning: "list.bullet.rectangle"
        case .permission: "lock.shield"
        case .executing: "hammer"
        case .monitoring: "waveform.path.ecg"
        case .checking: "checklist.checked"
        case .review: "checkmark.seal"
        case .delivering: "shippingbox"
        case .blocked: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .dormant: Color.lingFaint
        case .intake: .cyan
        case .memory: .purple
        case .planning: .indigo
        case .permission: .orange
        case .executing: .lingHolo
        case .monitoring: .teal
        case .checking: .green
        case .review: .green
        case .delivering: .brown
        case .blocked: .red
        }
    }
}

extension String {
    var eventColor: Color {
        switch self {
        case "ok": .green
        case "info": .teal
        case "medium": .orange
        case "high": .red
        default: Color.lingFaint
        }
    }
}

extension LingShuTraceKind {
    var icon: String {
        switch self {
        case .system: "sparkles"
        case .route: "arrow.triangle.branch"
        case .runtime: "hammer"
        case .model: "brain.head.profile"
        case .agent: "person.3.sequence"
        case .tool: "terminal"
        case .warning: "exclamationmark.triangle"
        case .result: "checkmark.seal"
        }
    }

    var color: Color {
        switch self {
        case .system: Color.lingHolo
        case .route: .cyan
        case .runtime: .orange
        case .model: .indigo
        case .agent: .orange
        case .tool: .green
        case .warning: .red
        case .result: .teal
        }
    }
}

extension LingShuTaskExecutionStatus {
    var color: Color {
        switch self {
        case .queued: .purple
        case .running: .lingHolo
        case .answered: .cyan
        case .dispatched: .orange
        case .completed: .green
        case .needsRevision: .orange
        case .blocked: .red
        case .suspended: .yellow   // 网络中断暂停:黄色(区别于红色"异常"——它会自动续)
        }
    }
}

extension LingShuTaskExecutionMessageKind {
    var icon: String {
        switch self {
        case .user: "person.fill"
        case .core: "sparkles"
        case .memory: "memorychip"
        case .router: "arrow.triangle.branch"
        case .agent: "person.3.sequence"
        case .model: "brain.head.profile"
        case .review: "checkmark.seal"
        case .result: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .user: .lingHolo
        case .core: .cyan
        case .memory: .purple
        case .router: .teal
        case .agent: .orange
        case .model: .indigo
        case .review: .green
        case .result: .green
        case .warning: .red
        }
    }
}

extension Date {
    var taskRecordDisplayTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding(18)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.07))
            }
    }
}

extension Color {
    static let lingVoid = Color(red: 0.018, green: 0.026, blue: 0.032)
    static let lingHolo = Color(red: 0.22, green: 0.94, blue: 0.86)
    static let lingHoloAlt = Color(red: 0.25, green: 0.55, blue: 1.0)
    static let lingBackground = Color(red: 0.945, green: 0.955, blue: 0.955)
    static let lingPanel = Color(red: 0.968, green: 0.974, blue: 0.972)
    static let lingSidebar = Color(red: 0.105, green: 0.125, blue: 0.128)
    static let lingInk = Color(red: 0.075, green: 0.105, blue: 0.11)
    static let lingMuted = Color(red: 0.36, green: 0.42, blue: 0.43)
    static let lingFaint = Color(red: 0.58, green: 0.63, blue: 0.64)
    static let lingAccent = Color(red: 0.0, green: 0.48, blue: 0.45)
}
