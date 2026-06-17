import Foundation

/// ANCS（Apple Notification Center Service）线协议 · **纯解析逻辑（可单测，无 CoreBluetooth 依赖）**。
///
/// 把 §3 的字节级协议抽成纯函数，这样即便手上没有可配对的真 iPhone，也能用单测验证
/// "Notification Source 8 字节包解析 / Control Point 请求构造 / Data Source 分片重组"全部正确——
/// 符合 [[no-fake-demos]]：解析逻辑是真的、可验证的，蓝牙链路能否打通才是 M0 spike 的未知数。
enum LingShuANCSProtocol {
    // Apple 固定 UUID（§3）
    static let serviceUUID = "7905F431-B5CE-4E99-A40F-4B1E122D00D0"
    static let notificationSourceUUID = "9FBF120D-6301-42D9-8C58-25E699A21DBD"
    static let controlPointUUID = "69D1D8F0-45E1-49A8-9821-9BBDFDAAD9D9"
    static let dataSourceUUID = "22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB"

    enum EventID: UInt8 { case added = 0, modified = 1, removed = 2 }

    enum CommandID: UInt8 { case getNotificationAttributes = 0, getAppAttributes = 1 }

    /// GetNotificationAttributes 请求里要拿的属性 ID。
    enum NotificationAttributeID: UInt8 {
        case appIdentifier = 0
        case title = 1
        case subtitle = 2
        case message = 3
        case messageSize = 4
        case date = 5
        /// 1/2/3（标题/副标题/正文）需要附带 2 字节最大长度。
        var needsMaxLength: Bool { self == .title || self == .subtitle || self == .message }
    }

    /// Notification Source 推送的 8 字节包。
    struct SourcePacket: Equatable, Sendable {
        let eventID: EventID
        let eventFlags: UInt8
        let categoryID: UInt8
        let categoryCount: UInt8
        let notificationUID: UInt32

        var categoryName: String { LingShuANCSProtocol.categoryName(categoryID) }
        var isPreExisting: Bool { eventFlags & 0x04 != 0 }   // bit2 = PreExisting
        var isImportant: Bool { eventFlags & 0x02 != 0 }     // bit1 = Important
        var isSilent: Bool { eventFlags & 0x01 != 0 }        // bit0 = Silent
    }

    /// 解析 Notification Source 8 字节包（little-endian UID）。
    static func parseSourcePacket(_ data: Data) -> SourcePacket? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        guard let event = EventID(rawValue: bytes[0]) else { return nil }
        let uid = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
        return SourcePacket(
            eventID: event,
            eventFlags: bytes[1],
            categoryID: bytes[2],
            categoryCount: bytes[3],
            notificationUID: uid
        )
    }

    /// CategoryID → 名称（与 `LingShuPhoneNotification.salience` 的 key 对齐）。
    static func categoryName(_ id: UInt8) -> String {
        switch id {
        case 0: "Other"
        case 1: "IncomingCall"
        case 2: "MissedCall"
        case 3: "Voicemail"
        case 4: "Social"
        case 5: "Schedule"
        case 6: "Email"
        case 7: "News"
        case 8: "HealthAndFitness"
        case 9: "BusinessAndFinance"
        case 10: "Location"
        case 11: "Entertainment"
        default: "Other"
        }
    }

    /// 构造 GetNotificationAttributes 请求字节流（写入 Control Point）。
    /// 默认请求：AppIdentifier / Title / Subtitle / Message / Date。
    static func buildGetNotificationAttributes(
        uid: UInt32,
        attributes: [NotificationAttributeID] = [.appIdentifier, .title, .subtitle, .message, .date],
        maxTextLength: UInt16 = 256
    ) -> Data {
        var data = Data()
        data.append(CommandID.getNotificationAttributes.rawValue)
        data.append(UInt8(uid & 0xFF))
        data.append(UInt8((uid >> 8) & 0xFF))
        data.append(UInt8((uid >> 16) & 0xFF))
        data.append(UInt8((uid >> 24) & 0xFF))
        for attr in attributes {
            data.append(attr.rawValue)
            if attr.needsMaxLength {
                data.append(UInt8(maxTextLength & 0xFF))
                data.append(UInt8((maxTextLength >> 8) & 0xFF))
            }
        }
        return data
    }

    /// Data Source 回包解析结果。
    struct AttributeResponse: Equatable, Sendable {
        let notificationUID: UInt32
        /// AttributeID → UTF-8 文本值。
        let attributes: [UInt8: String]
    }

    /// 解析 Data Source 回包（CommandID + UID + 多个 (AttrID, Len(2), Value) 元组）。
    /// 返回 nil 表示数据还不完整（需要继续累积分片后重试）。
    static func parseAttributeResponse(_ data: Data) -> AttributeResponse? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes[0] == CommandID.getNotificationAttributes.rawValue else { return nil }
        let uid = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8) | (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 24)
        var index = 5
        var attrs: [UInt8: String] = [:]
        while index + 3 <= bytes.count {
            let attrID = bytes[index]
            let length = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
            let valueStart = index + 3
            let valueEnd = valueStart + length
            guard valueEnd <= bytes.count else {
                // 分片未到齐：已解析到的属性先不返回，等更多字节。
                return attrs.isEmpty ? nil : AttributeResponse(notificationUID: uid, attributes: attrs)
            }
            let value = String(bytes: bytes[valueStart..<valueEnd], encoding: .utf8) ?? ""
            attrs[attrID] = value
            index = valueEnd
        }
        return AttributeResponse(notificationUID: uid, attributes: attrs)
    }

    /// 把属性表 + Source 包组装成归一的 `LingShuPhoneNotification`。
    static func makeNotification(
        sourceID: String,
        packet: SourcePacket,
        attributes: [UInt8: String]
    ) -> LingShuPhoneNotification {
        let appID = attributes[NotificationAttributeID.appIdentifier.rawValue] ?? ""
        return LingShuPhoneNotification(
            id: "\(sourceID)#\(packet.notificationUID)",
            uid: packet.notificationUID,
            appID: appID,
            appName: LingShuANCSProtocol.appDisplayName(forBundleID: appID),
            title: attributes[NotificationAttributeID.title.rawValue] ?? "",
            subtitle: attributes[NotificationAttributeID.subtitle.rawValue] ?? "",
            body: attributes[NotificationAttributeID.message.rawValue] ?? "",
            date: LingShuANCSProtocol.parseANCSDate(attributes[NotificationAttributeID.date.rawValue]) ?? Date(),
            category: packet.categoryName
        )
    }

    /// ANCS 日期格式：`yyyyMMdd'T'HHmmss`。
    static func parseANCSDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    /// 常见 app bundle id → 中文显示名（拿不到 GetAppAttributes 时的兜底映射）。
    static func appDisplayName(forBundleID bundleID: String) -> String {
        switch bundleID {
        case "com.tencent.xin": "微信"
        case "com.alibaba.DingTalk": "钉钉"
        case "com.apple.MobileSMS": "信息"
        case "com.apple.mobilecal": "日历"
        case "com.apple.mobilemail": "邮件"
        case "com.tencent.mqq": "QQ"
        case "com.bytedance.feishu": "飞书"
        case "": "未知应用"
        default:
            // 取 bundle id 末段做兜底显示名。
            bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
    }
}
