import SwiftUI
import WebKit
import AppKit

/// 内置多 tab 浏览器的独立窗口(与演示预览窗同款:观察 `isPresented` 开/收窗,本体浮窗全程在位)。
struct LingShuBrowserHost: NSViewRepresentable {
    @ObservedObject var controller: LingShuBrowserController

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.sync(controller: controller) }
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var window: NSWindow?
        private weak var controller: LingShuBrowserController?

        func sync(controller: LingShuBrowserController) {
            self.controller = controller
            if controller.isPresented, window == nil {
                let host = NSHostingController(rootView: LingShuBrowserChrome(controller: controller))
                let w = NSWindow(contentViewController: host)
                w.title = "灵枢浏览器"
                w.setContentSize(NSSize(width: 1100, height: 760))
                w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
                w.collectionBehavior.insert(.fullScreenPrimary)
                w.isReleasedWhenClosed = false
                w.delegate = self
                w.center()
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
                window = w
            } else if !controller.isPresented, let w = window {
                w.delegate = nil; w.close(); window = nil
            }
        }

        func windowWillClose(_ notification: Notification) {
            window = nil
            if controller?.isPresented == true { _ = controller?.close() }
        }
    }
}

/// 浏览器窗口内容:tab 栏 + 地址栏/导航按钮 + 活动 tab 的 WKWebView。
struct LingShuBrowserChrome: View {
    @ObservedObject var controller: LingShuBrowserController
    @State private var addressText = ""

    var body: some View {
        VStack(spacing: 0) {
            if !controller.fullscreen {
                tabBar
                addressBar
            }
            LingShuBrowserWebContainer(controller: controller)
                .frame(minWidth: 760, minHeight: 520)
        }
        .frame(minWidth: controller.fullscreen ? nil : 940, maxWidth: .infinity,
               minHeight: controller.fullscreen ? nil : 680, maxHeight: .infinity)
        .background(Color.lingVoid)
        .background(BrowserFullscreenToggler(active: controller.fullscreen))
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(controller.tabs.enumerated()), id: \.element.id) { i, tab in
                    HStack(spacing: 6) {
                        Text(tab.title.isEmpty ? "新标签页" : tab.title)
                            .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Button { _ = controller.closeTab(index: i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(Color.lingFg.opacity(0.5))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: 200)
                    .background(tab.id == controller.activeTabID ? Color.lingHolo.opacity(0.25) : Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(tab.id == controller.activeTabID ? Color.white : Color.lingFg.opacity(0.7))
                    .onTapGesture { _ = controller.switchTab(index: i) }
                }
                Button { _ = controller.openTab("about:blank") } label: { Image(systemName: "plus").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.lingFg.opacity(0.7)).padding(.horizontal, 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.5))
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            Button { _ = controller.navigate("back") } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Button { _ = controller.navigate("forward") } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            Button { _ = controller.navigate("reload") } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
            TextField("输入网址,回车打开", text: $addressText, onCommit: {
                guard !addressText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                _ = controller.navigate(addressText)
            })
            .textFieldStyle(.roundedBorder).font(.system(size: 12))
            Button { _ = controller.setFullscreen(!controller.fullscreen) } label: { Image(systemName: controller.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain)
            Button { _ = controller.close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Color.lingFg.opacity(0.6))
        }
        .foregroundStyle(Color.lingFg.opacity(0.85))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.black.opacity(0.4))
        .onChange(of: controller.activeTabID) { _ in addressText = controller.activeTab?.url ?? "" }
    }
}

/// 把活动 tab 的 WKWebView 装进容器(切 tab 时换 subview;各 tab 的 webView 持久存在 controller 里)。
private struct LingShuBrowserWebContainer: NSViewRepresentable {
    @ObservedObject var controller: LingShuBrowserController

    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.black.cgColor; return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let web = controller.activeTab?.webView else {
            container.subviews.forEach { $0.removeFromSuperview() }; return
        }
        if web.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            web.frame = container.bounds
            web.autoresizingMask = [.width, .height]
            container.addSubview(web)
        }
    }
}

/// 浏览器窗全屏(撑满可见区,与演示窗同款——本体浮窗仍可见)。
private struct BrowserFullscreenToggler: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if active {
                if coordinator.savedFrame == nil { coordinator.savedFrame = window.frame }
                if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true, animate: true) }
                NSApp.activate(ignoringOtherApps: true); window.orderFrontRegardless()
            } else if let saved = coordinator.savedFrame {
                window.setFrame(saved, display: true, animate: true); coordinator.savedFrame = nil
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var savedFrame: NSRect? }
}
