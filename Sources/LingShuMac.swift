import SwiftUI
import AppKit
import Combine

final class LingShuAppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        LingShuRuntimeEnvironment.preferences.set(true, forKey: "ApplePersistenceIgnoreState")
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

    func application(_ sender: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool { false }
    func application(_ sender: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    private static func removeSavedApplicationState() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let savedStateURL = LingShuRuntimeEnvironment.homeDirectory
            .appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
    }
}

enum LingShuWindowPlacement {
    @MainActor private static var savedStandardFrame: NSRect?

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
            guard window.level != .floating else { return }
            configureWindowSurface(window)
            centerWindowOnMainScreen(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private static func shouldManage(_ window: NSWindow) -> Bool {
        ["灵枢", "Nous", "LingShu"].contains(window.title)
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
        let frame = NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                           width: width, height: height)
        window.setFrame(frame, display: true)
    }
}

@main
struct LingShuMacApp: App {
    @NSApplicationDelegateAdaptor(LingShuAppDelegate.self) private var appDelegate
    @StateObject private var state = LingShuState()
    @StateObject private var voice = VoiceIOManager()
    @StateObject private var vision = VisionIOManager()
    @StateObject private var perceptionGateway = LingShuRealtimePerceptionGateway()

    var body: some Scene {
        WindowGroup(state.appName) {
            LingShuRootView(
                state: state,
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway
            )
            .task {
                await LingShuCleanUserSmokeCoordinator.runIfRequested(state: state)
            }
            .task(id: state.hasCompletedInitialLanguageSelection) {
                guard state.hasCompletedInitialLanguageSelection else { return }
                guard LingShuRuntimeEnvironment.allowsBackgroundServices else { return }
                LingShuControlServer.shared.start(state: state)
                LingShuMainActorWatchdog.shared.start(state: state)
                await state.prepareLoopRuntimeOnLaunch()
                if await state.prepareBrainOnLaunch() {
                    _ = await state.mainAgentSession()
                }
                LingShuQuickAskController.shared.install(state: state)
                LingShuFolderWatcher.shared.start(state: state)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1360, height: 900)
        .commands {
            LingShuPublicHelpCommands(state: state)
        }
        MenuBarExtra(state.appName, systemImage: "brain") {
            if state.hasCompletedInitialLanguageSelection {
                Text("\(state.loc("状态", "Status")): \(state.coreStateDisplay)")
                if state.hasActiveModelCall {
                    Text("\(state.loc("后台任务", "Background task")): \(state.missionTitle)")
                }
                let enabledTriggers = state.scheduledTriggers.triggers.filter(\.enabled).count
                if enabledTriggers > 0 {
                    Text(state.loc("定时任务：\(enabledTriggers) 个待触发", "Scheduled tasks: \(enabledTriggers) pending"))
                }
                Divider()
                Button(state.loc("快速提问 / 找东西 (⌥Space)", "Quick Ask / Find (⌥Space)")) {
                    LingShuQuickAskController.shared.toggle()
                }
                Button(state.loc("打开主窗口", "Open Main Window")) {
                    NSApp.setActivationPolicy(.regular)
                    LingShuWindowPlacement.bringWindowsToMainScreen()
                }
                Button(state.loc("退出灵枢", "Quit \(state.appName)")) {
                    NSApp.terminate(nil)
                }
            } else {
                Text("请选择语言 · Choose a language")
                Divider()
                Button("打开语言选择 · Open Language Selection") {
                    NSApp.setActivationPolicy(.regular)
                    LingShuWindowPlacement.bringWindowsToMainScreen()
                }
                Button("退出 · Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
