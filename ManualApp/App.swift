import AppKit

final class ManualAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(red: 0.02, green: 0.05, blue: 0.05, alpha: 1).cgColor

        let label = NSTextField(labelWithString: "灵枢启动测试")
        label.font = .systemFont(ofSize: 32, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "灵枢"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

let app = NSApplication.shared
let delegate = ManualAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
