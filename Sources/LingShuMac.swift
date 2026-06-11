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
    @MainActor
    static func bringWindowsToMainScreen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.forEach { window in
            guard shouldManage(window) else { return }
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
            LingShuRootView()
                .frame(minWidth: 1240, minHeight: 820)
        }
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
