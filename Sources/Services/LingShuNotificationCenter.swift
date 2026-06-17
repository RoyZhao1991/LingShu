import Foundation
import UserNotifications

/// 系统通知中枢:封装 `UNUserNotificationCenter`,让灵枢能推 macOS 系统通知横幅(主动提醒)。
///
/// 用途:会议纪要生成完、屏幕异常哨兵发现问题、长任务完成等——**主人不在电脑前也能在通知中心看到**。
/// 前台也展示横幅(delegate 的 willPresent 返回 banner)。需用户授权一次(配置页可主动授予)。
@MainActor
final class LingShuNotificationCenter: NSObject, ObservableObject {
    static let shared = LingShuNotificationCenter()

    /// 是否已获通知授权(配置页据此显示状态)。
    @Published private(set) var authorized = false
    /// 是否已查得授权状态(未查到前 UI 显示"检测中")。
    @Published private(set) var statusKnown = false

    private override init() { super.init() }

    /// 启动时调:设代理(前台也弹横幅)+ 查当前授权状态。
    func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
        refreshStatus()
    }

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            // 在回调线程先取出 Sendable 的 Bool,别把非 Sendable 的 settings 带过 actor 边界。
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in
                self?.statusKnown = true
                self?.authorized = ok
            }
        }
    }

    /// 主动请求通知授权(首次弹系统授权框;之后系统不再弹,需去设置改)。
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                self?.statusKnown = true
                self?.refreshStatus()
            }
        }
    }

    /// 推一条系统通知(立即触达)。未授权时静默失败(不抛错、不打断)。
    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "灵枢" : title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension LingShuNotificationCenter: UNUserNotificationCenterDelegate {
    /// app 在前台时也展示横幅 + 声音(否则前台收到的通知不弹)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
