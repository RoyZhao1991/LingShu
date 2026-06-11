import SwiftUI
import AppKit
import Combine

final class LingShuAppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        Self.removeSavedApplicationState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            LingShuWindowPlacement.bringWindowsToMainScreen()
        }
    }

    func application(_ sender: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ sender: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    private static func removeSavedApplicationState() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let savedStateURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
    }
}

enum LingShuWindowPlacement {
    /// 进入极简模式前的主窗布局，退出时原样恢复。
    @MainActor private static var savedStandardFrame: NSRect?

    /// 极简语音模式 = 一个小小的常浮窗口（视频画面 + 两条音轨），不再占满整个主窗。
    /// 进入时收到屏幕右下角并置顶，退出时恢复原来的标准窗口。
    @MainActor
    static func applyMinimalVoiceWindow(_ minimal: Bool) {
        guard let window = NSApp.windows.first(where: { shouldManage($0) }) else { return }

        if minimal {
            savedStandardFrame = window.frame
            window.minSize = NSSize(width: 320, height: 480)
            window.level = .floating
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            let size = NSSize(width: 340, height: 560)
            let screen = window.screen ?? NSScreen.main
            let origin: NSPoint
            if let visible = screen?.visibleFrame {
                origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
            } else {
                origin = window.frame.origin
            }
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        } else {
            window.level = .normal
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.minSize = NSSize(width: 1240, height: 820)
            if let savedStandardFrame {
                window.setFrame(savedStandardFrame, display: true, animate: true)
            } else {
                centerWindowOnMainScreen(window)
            }
        }
    }

    @MainActor
    static func bringWindowsToMainScreen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.forEach { window in
            guard shouldManage(window) else { return }
            // 极简模式的小浮窗（level 已置顶）不参与标准窗口归位，避免被强行撑回大窗。
            guard window.level != .floating else { return }
            configureWindowSurface(window)
            centerWindowOnMainScreen(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private static func shouldManage(_ window: NSWindow) -> Bool {
        window.title == "灵枢"
    }

    @MainActor
    private static func configureWindowSurface(_ window: NSWindow) {
        let backingColor = NSColor(red: 0.018, green: 0.026, blue: 0.032, alpha: 1.0)
        window.isOpaque = true
        window.alphaValue = 1.0
        window.backgroundColor = backingColor
        window.titlebarAppearsTransparent = false
        window.hasShadow = true
        window.isRestorable = false
        window.tabbingMode = .disallowed
    }

    @MainActor
    private static func centerWindowOnMainScreen(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.minX >= 0 && $0.frame.minY >= 0 }) ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let width = min(max(window.frame.width, 1240), visibleFrame.width - 40)
        let height = min(max(window.frame.height, 820), visibleFrame.height - 40)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )

        window.setFrame(frame, display: true)
    }
}

@main
struct LingShuMacApp: App {
    @NSApplicationDelegateAdaptor(LingShuAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("灵枢") {
            // 尺寸约束在 LingShuRootView 内部按模式切换：
            // 标准界面 ≥1240×820，极简语音模式收成 340×560 的小浮窗。
            LingShuRootView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1360, height: 900)
        .commands {
            CommandMenu("灵枢") {
                Button("演示一次能力流转") {
                    NotificationCenter.default.post(name: .startDemoMission, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("执行工程验证") {
                    NotificationCenter.default.post(name: .runEngineeringValidation, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let startDemoMission = Notification.Name("startDemoMission")
    static let runEngineeringValidation = Notification.Name("runEngineeringValidation")
}
