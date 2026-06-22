import Foundation

/// 完全版 #5·**统一权限求值器**(纯逻辑、可测、单一真相)。
///
/// 把分散的权限判断(命令安全 / dev full access / shell approval / 自主权限级)codify 成一个矩阵:
/// `裁决 = f(资源域, 风险级别, 运行模式, 是否已持久授权)`。**安全红线在这里硬编码、不随任何旋钮放松**
/// (供应链/未审代码恒拒、不可逆/系统级恒先确认、紧急停止全拒)。现有调用点保留;这是它们可统一咨询的核。
/// 注:这是**求值核**;可视化矩阵 UI 是后续产品层。
enum LingShuResourceDomain: String, Sendable, CaseIterable {
    case file, terminal, network, browser, microphone, camera, speaker
    case systemControl       // 系统设置/进程/电源等
    case externalAccount     // 外部账号(邮箱/云盘/社交)
    case privateKnowledge    // 本机私密知识库
    case supplyChain         // 安装/执行未审第三方代码(供应链)
}

enum LingShuRiskLevel: Int, Sendable, Comparable {
    case readonly = 0        // 纯读/查
    case low = 1             // 工作目录内写、可逆
    case medium = 2          // 跑命令/装依赖、外发非敏感
    case high = 3            // 删改大量数据、对外发布、外部账号操作
    case critical = 4        // 不可逆且无法合理假设 / 系统级敏感 / 供应链
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum LingShuRunMode: String, Sendable {
    case readOnly            // 只观察
    case standard            // 普通(高风险走审批)
    case developerFull       // 开发者全权(dev-full-access)
    case autonomous          // 无人值守自主运行
    case presentation        // 演示/汇报
    case emergencyStop       // 紧急停止
}

enum LingShuPermissionVerdict: String, Sendable, Equatable {
    case allow               // 直接放行
    case askUser             // 弹审批/先确认
    case deny                // 拒绝(不弹框)
}

enum LingShuPermissionMatrix {
    /// 核心裁决。`durablyAllowed`=本会话/本资源已被主人持久授权(如"完全授权"勾过)。
    static func decide(domain: LingShuResourceDomain,
                       risk: LingShuRiskLevel,
                       mode: LingShuRunMode,
                       durablyAllowed: Bool = false) -> LingShuPermissionVerdict {
        // —— 不可放松的红线(任何模式/旋钮都不松)——
        if mode == .emergencyStop { return .deny }                 // 紧急停止:全拒
        if domain == .supplyChain { return .deny }                 // 供应链/未审代码:恒拒(只能经显式审批解隔离,不在此放行)
        if risk == .critical {
            // 不可逆/系统级:绝不自动放行;无人值守=拒,有人在=先确认。
            return mode == .autonomous ? .deny : .askUser
        }

        // —— 只读永远放行 ——
        if risk == .readonly { return .allow }

        // —— 按运行模式(穷尽 6 种)——
        switch mode {
        case .emergencyStop:
            return .deny                                           // 已前置处理,穷尽兜底
        case .readOnly:
            return .deny                                           // 只读模式:非只读风险一律拒(观察不动手)
        case .developerFull:
            // 开发者全权:低/中放行;高风险先确认(除非已持久授权)。
            return risk >= .high ? (durablyAllowed ? .allow : .askUser) : .allow
        case .presentation:
            // 演示:低风险放行(翻页/读),中及以上先确认(别在台上乱动)。
            return risk >= .medium ? .askUser : .allow
        case .autonomous:
            // 无人值守:低风险放行;中风险看是否持久授权;高风险先确认/拒(无人在场不擅自做不可控的)。
            if risk == .low { return .allow }
            if risk == .medium { return durablyAllowed ? .allow : .askUser }
            return durablyAllowed ? .askUser : .deny
        case .standard:
            // 普通:低放行,中及以上走审批。
            return risk >= .medium ? (durablyAllowed ? .allow : .askUser) : .allow
        }
    }
}
