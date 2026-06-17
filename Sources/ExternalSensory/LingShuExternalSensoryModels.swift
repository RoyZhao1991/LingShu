import Foundation

/// 外接设备感知 · 纯领域模型（无 UI / 无 State / 可单测）。
///
/// 设计取向（用户拍板 2026-06-17）：**每一类外接设备感知都是一个独立模块、独立线程**
/// （手机通知 / 可穿戴 / 智能家居 / 传感器…），它们在**一个特定的汇聚阶段**被归一成一套
/// **标准输入**（`LingShuExternalSensoryReading`），与视觉/听觉一样集中喂给大模型，由大模型
/// 综合评判——这里只供给**事实**，绝不写死"该不该提醒/怎么处理"的策略。模块之间可无缝切换
/// （启用即起线程订阅、停用即停线程，互不影响）。
///
/// 隐私红线 [[perception-data-zero-retention]]：通知正文全程本地、只读、不落盘、不出网（除非
/// 用户显式选了云抽取且只传去标识后的最小文本）；模块默认关闭、配对需用户在设备上确认。

// MARK: - 感知通道（"第六感"分类，类比 视觉/听觉/触觉/味觉）

enum LingShuExternalSensoryChannel: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// 手机系统通知（ANCS：微信/钉钉/iMessage/日历…一切出现在通知中心的消息）。
    case phoneNotifications
    /// 日历 + 提醒事项（EventKit，零配对，最稳起步源）。
    case calendar
    /// 本机 iMessage / 短信库（后续）。
    case messages
    /// 可穿戴设备体征（后续：心率/活动…）。
    case wearable
    /// 智能家居 / IoT 设备状态（后续）。
    case smartHome

    var label: String {
        switch self {
        case .phoneNotifications: "手机通知"
        case .calendar: "日历提醒"
        case .messages: "短信消息"
        case .wearable: "穿戴体征"
        case .smartHome: "智能家居"
        }
    }

    var englishLabel: String {
        switch self {
        case .phoneNotifications: "Phone Alerts"
        case .calendar: "Calendar"
        case .messages: "Messages"
        case .wearable: "Wearable"
        case .smartHome: "Smart Home"
        }
    }

    /// SF Symbol，UI 用。
    var icon: String {
        switch self {
        case .phoneNotifications: "iphone.radiowaves.left.and.right"
        case .calendar: "calendar"
        case .messages: "message"
        case .wearable: "applewatch"
        case .smartHome: "house"
        }
    }
}

// MARK: - 模块运行状态（UI / 大脑可读）

enum LingShuExternalSensoryStatus: Equatable, Sendable {
    /// 未启用（默认）。
    case disabled
    /// 启用中、尚未连上（扫描 / 等待配对）。
    case connecting
    /// 等待用户在设备上确认配对。
    case pairing
    /// 已连上、正在接收信号。
    case streaming
    /// 平台不放行 / 缺权限 / 硬件不可用——带可解释原因。
    case unavailable(String)

    var label: String {
        switch self {
        case .disabled: "未启用"
        case .connecting: "连接中"
        case .pairing: "等待配对确认"
        case .streaming: "接收中"
        case .unavailable(let reason): "不可用：\(reason)"
        }
    }

    var isActive: Bool {
        switch self {
        case .disabled, .unavailable: false
        case .connecting, .pairing, .streaming: true
        }
    }
}

// MARK: - 标准输入单元（汇聚阶段的统一事实）

/// 任意外接设备归一后的**一条标准感知读数**——这是各模块汇聚成"一套标准输入"的最小单位。
/// 大模型只看这套统一结构，不关心它来自蓝牙、EventKit 还是别的传感器。
struct LingShuExternalSensoryReading: Identifiable, Equatable, Sendable {
    let id: UUID
    let channel: LingShuExternalSensoryChannel
    let sourceID: String
    let timestamp: Date
    /// 一句话归一标题（如"微信 · 张三：明天的合同还没签"）。
    let headline: String
    /// 正文/副标题（可空；隐私敏感，仅留在内存）。
    let detail: String?
    /// 类别（Social/Email/Schedule/IncomingCall…，来自 ANCS CategoryID 或推断）。
    let category: String?
    /// 来源 app 显示名（微信/钉钉/日历…）。
    let originApp: String?
    /// 显著度提示 0…3（0=噪声，3=关键/紧急），供降噪与排序，不替模型下结论。
    let salience: Int
    /// 透传元数据（去重 UID、EventFlags 等）。
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        channel: LingShuExternalSensoryChannel,
        sourceID: String,
        timestamp: Date = Date(),
        headline: String,
        detail: String? = nil,
        category: String? = nil,
        originApp: String? = nil,
        salience: Int = 1,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.channel = channel
        self.sourceID = sourceID
        self.timestamp = timestamp
        self.headline = headline
        self.detail = detail
        self.category = category
        self.originApp = originApp
        self.salience = max(0, min(3, salience))
        self.metadata = metadata
    }
}

// MARK: - 手机通知（ANCS 归一结构，§3/§4）

/// 手机系统通知归一结构（对应方案 §4 的 `PhoneNotification`）。
struct LingShuPhoneNotification: Identifiable, Equatable, Sendable {
    let id: String          // 去重键：sourceID + ANCS NotificationUID
    let uid: UInt32
    let appID: String
    let appName: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date
    let category: String

    /// 映射成标准输入读数（汇聚到统一感知流）。
    func asReading(sourceID: String) -> LingShuExternalSensoryReading {
        let who = appName.isEmpty ? appID : appName
        let subjectParts = [title, subtitle].filter { !$0.isEmpty }
        let subject = subjectParts.joined(separator: " · ")
        let headline = subject.isEmpty ? "\(who) 新通知" : "\(who) · \(subject)"
        return LingShuExternalSensoryReading(
            channel: .phoneNotifications,
            sourceID: sourceID,
            timestamp: date,
            headline: headline,
            detail: body.isEmpty ? nil : body,
            category: category,
            originApp: who,
            salience: LingShuPhoneNotification.salience(forCategory: category),
            metadata: ["uid": String(uid), "appID": appID]
        )
    }

    /// ANCS CategoryID → 粗显著度（仅排序/降噪用，不下结论）。
    static func salience(forCategory category: String) -> Int {
        switch category.lowercased() {
        case "incomingcall", "missedcall", "schedule", "email": 3
        case "social", "news", "businessandfinance", "healthandfitness": 2
        case "other", "": 1
        case "advertisement", "entertainment", "promotion": 0
        default: 1
        }
    }
}

// MARK: - 关键待办（蒸馏产物，M3）

/// 由通知流蒸馏出的**真需行动的关键待办**（方案 §4 的 `PhoneTodo`）。
struct LingShuPhoneTodo: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    /// 一句话待办标题。
    var title: String
    /// 来源 app（微信/钉钉/日历…）。
    var sourceApp: String
    /// 截止/相关时间（自然语言或解析后的日期描述，可空）。
    var due: String?
    /// 涉及人。
    var people: [String]
    /// 行动建议（灵枢给的下一步）。
    var actionSuggestion: String
    /// 原文引用（最小必要片段，便于用户核对）。
    var sourceQuote: String
    /// 蒸馏时间。
    var distilledAt: Date = Date()
    /// 预备好的资料（M4，MaterialPrepper 产出；尚未预备为空）。
    var preparedMaterial: String?

    init(
        id: UUID = UUID(),
        title: String,
        sourceApp: String,
        due: String? = nil,
        people: [String] = [],
        actionSuggestion: String = "",
        sourceQuote: String = "",
        distilledAt: Date = Date(),
        preparedMaterial: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.due = due
        self.people = people
        self.actionSuggestion = actionSuggestion
        self.sourceQuote = sourceQuote
        self.distilledAt = distilledAt
        self.preparedMaterial = preparedMaterial
    }
}
