import SwiftUI

/// 灵枢表现层的情绪/动作态。
/// 这里描述的是“身体怎么表现”，不参与业务决策；业务决策仍归大脑/agent loop。
enum LingShuDigitalHumanExpression: String, CaseIterable, Codable, Equatable, Identifiable {
    case standby
    case listening
    case receiving   // 自主/在岗:正在接收主人输入(绿色「我在听」)
    case speaking
    case thinking
    case executing
    case alert
    case greeting
    case confirming
    case presenting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standby: "待机"
        case .listening: "聆听"
        case .receiving: "我在听"
        case .speaking: "发声"
        case .thinking: "思考"
        case .executing: "执行"
        case .alert: "警戒"
        case .greeting: "回应"
        case .confirming: "确认"
        case .presenting: "演示"
        }
    }

    var accent: Color {
        switch self {
        case .standby: .lingHolo
        case .listening: .cyan
        case .receiving: .green
        case .speaking: .green
        case .thinking: .cyan
        case .executing: .orange
        case .alert: .red
        case .greeting: .lingHolo
        case .confirming: .green
        case .presenting: .purple
        }
    }

    var baseIntensity: Double {
        switch self {
        case .standby: 0.18
        case .listening: 0.72
        case .receiving: 0.74
        case .speaking: 0.86
        case .thinking: 0.92
        case .executing: 0.78
        case .alert: 1.0
        case .greeting: 0.62
        case .confirming: 0.58
        case .presenting: 0.82
        }
    }

    static func parse(_ value: String) -> LingShuDigitalHumanExpression? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let direct = Self(rawValue: normalized) { return direct }
        switch normalized {
        case "idle", "ready", "待机", "待命": return .standby
        case "listen", "hearing", "聆听", "听", "收声": return .listening
        case "receiving", "receive", "接收", "接收输入", "我在听": return .receiving
        case "speak", "talking", "发声", "说话", "口播": return .speaking
        case "think", "思考", "分析": return .thinking
        case "execute", "working", "执行", "工作": return .executing
        case "warning", "abnormal", "警戒", "异常", "告警": return .alert
        case "greet", "回应", "问候": return .greeting
        case "confirm", "确认", "通过": return .confirming
        case "present", "presentation", "演示", "汇报": return .presenting
        default: return nil
        }
    }
}

enum LingShuDigitalHumanSignal: String, CaseIterable, Codable, Equatable, Identifiable {
    case ear
    case mouth
    case eye
    case brain
    case hand
    case owner

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ear: "耳"
        case .mouth: "口"
        case .eye: "眼"
        case .brain: "脑"
        case .hand: "手"
        case .owner: "主"
        }
    }
}

struct LingShuDigitalHumanDirective: Codable, Equatable {
    var expression: LingShuDigitalHumanExpression
    var message: String
    var source: String
    var intensity: Double
    var issuedAt: Date
    var expiresAt: Date?

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}

struct LingShuDigitalHumanSnapshot: Equatable {
    var expression: LingShuDigitalHumanExpression
    var displayText: String
    var source: String
    var intensity: Double
    var activeSignals: Set<LingShuDigitalHumanSignal>
    var isDirectiveDriven: Bool

    var accent: Color { expression.accent }

    func signalIsActive(_ signal: LingShuDigitalHumanSignal) -> Bool {
        activeSignals.contains(signal)
    }
}
