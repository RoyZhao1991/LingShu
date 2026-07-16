import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 常驻全局入口·**"问/找/做"快速面板**(本机知识中枢愿景 ③:打开灵枢少碰 OS)。
/// ⌥Space 从任何地方唤起一个 Spotlight 式浮窗:输入自然语言 → 走完整 agent(可 recall_local 按本机知识答 / 直接做事),
/// 回复实时显示在面板里。Esc 收起。复用主会话 `submitTextWithAttachments`,不另开一套大脑。
@MainActor
final class LingShuQuickAskController {
    static let shared = LingShuQuickAskController()
    private var panel: LingShuQuickAskPanel?
    private var hotKey: LingShuGlobalHotKey?
    private weak var state: LingShuState?

    /// 在 App 启动(state 就绪)时安装:注册 ⌥Space 全局热键。幂等。
    func install(state: LingShuState) {
        self.state = state
        guard hotKey == nil else { return }
        // ⌥Space:kVK_Space = 49,Carbon optionKey 掩码。
        hotKey = LingShuGlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
    }

    func toggle() {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        show()
    }

    private func show() {
        guard let state else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentViewController = NSHostingController(
            rootView: LingShuQuickAskView(state: state, onClose: { [weak self] in self?.panel?.orderOut(nil) })
        )
        if let screen = NSScreen.main {
            let size = NSSize(width: 680, height: 420)
            let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                                 y: screen.frame.midY - size.height / 2 + 120)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> LingShuQuickAskPanel {
        let panel = LingShuQuickAskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

/// 可成为 key 的浮动面板(borderless 默认不能成 key,会接不到键盘输入)。
final class LingShuQuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct LingShuQuickAskView: View {
    @ObservedObject var state: LingShuState
    var onClose: () -> Void

    @State private var text = ""
    @State private var submitted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                TextField(state.loc("问灵枢 · 找东西 · 让它做事…", "Ask Nous · Find something · Get things done…"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit(submit)
                if state.hasActiveModelCall { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 6)

            if submitted, let reply = latestReply, !reply.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(reply)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let links = LingShuQuickAskLinks.extract(from: reply)
                        if !links.isEmpty {
                            Divider()
                            Text(state.loc("结果 · 可直接操作", "Results · Ready to use")).font(.system(size: 11)).foregroundStyle(.tertiary)
                            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                                HStack(spacing: 6) {
                                    Button { open(link) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: link.kind == .file ? "doc.text" : "safari").foregroundStyle(.secondary)
                                            Text(link.display).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    // 直接执行动作:打开 / 访达中显示(文件)/ 复制路径或网址
                                    if link.kind == .file {
                                        actionButton("folder", state.loc("在访达中显示", "Show in Finder")) { reveal(link) }
                                    }
                                    actionButton("doc.on.doc", state.loc("复制", "Copy")) { copyToClipboard(link) }
                                    actionButton("arrow.up.forward.app", link.kind == .file ? state.loc("打开", "Open") : state.loc("在浏览器打开", "Open in Browser")) { open(link) }
                                }
                                .padding(.vertical, 5).padding(.horizontal, 10)
                                .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else if submitted {
                Divider()
                Text(state.loc("灵枢正在处理…(可按本机知识检索)", "Nous is working… (local knowledge can be searched)"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text(state.loc("⌥Space 唤起 · Enter 发送 · Esc 收起", "⌥Space to open · Enter to send · Esc to close"))
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 680, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.lingFg.opacity(0.08)))
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)   // Esc
    }

    private var latestReply: String? {
        state.chatMessages.last(where: { !$0.isUser })?.text
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        _ = state.submitTextWithAttachments(t, source: .typed)
        text = ""
        submitted = true
    }

    /// 结果行的小动作按钮(直接执行动作)。
    private func actionButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(5).background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(help)
    }

    /// 点开一个结果:文件→默认 app 打开,网址→浏览器打开。
    private func open(_ link: LingShuQuickLink) {
        switch link.kind {
        case .file: NSWorkspace.shared.open(URL(fileURLWithPath: link.target))
        case .url: if let u = URL(string: link.target) { NSWorkspace.shared.open(u) }
        }
    }

    /// 在访达中显示(文件)。
    private func reveal(_ link: LingShuQuickLink) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: link.target)])
    }

    /// 复制路径/网址到剪贴板。
    private func copyToClipboard(_ link: LingShuQuickLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.target, forType: .string)
    }
}
