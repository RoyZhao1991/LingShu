import SwiftUI
import PDFKit
import AppKit
import WebKit

/// 预览面板挂到**独立窗口**(不再是主窗口上的 sheet)——用户定调 2026-06-17:演示 PPT 另开一个窗,
/// 灵枢本体浮窗**全程在位**(右上角),可实时看到灵枢状态;演示窗与主窗/本体互不干扰(根治"无边框小窗+sheet+全屏=黑屏卡死")。
/// 观察 `controller.isPresented`:大脑 open_preview → 开窗;close_preview / 用户关窗 → 同步收掉。
struct LingShuPreviewHost: NSViewRepresentable {
    @ObservedObject var controller: LingShuPreviewController

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(controller: controller)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var window: NSWindow?
        private weak var controller: LingShuPreviewController?

        func sync(controller: LingShuPreviewController) {
            self.controller = controller
            if controller.isPresented, window == nil {
                let host = NSHostingController(rootView: LingShuPreviewSheet(controller: controller))
                let w = NSWindow(contentViewController: host)
                w.title = "灵枢演示"
                w.setContentSize(NSSize(width: 1040, height: 720))
                w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
                w.collectionBehavior.insert(.fullScreenPrimary)
                w.isReleasedWhenClosed = false
                w.delegate = self
                w.center()
                w.makeKeyAndOrderFront(nil)
                // 自主/在岗模式下 app 在后台(化身右上角 orb),`makeKeyAndOrderFront` 只在 app 是活动应用时才把窗提到
                // 全屏最前——后台时演示窗开了却被压在别的 app 后面(用户实测:PPT 没自动置于最前端)。演示材料**必须显示出来**
                // 才有意义:强制激活 app + 越过其它 app 置顶。
                NSApp.activate(ignoringOtherApps: true)
                w.orderFrontRegardless()
                window = w
            } else if !controller.isPresented, let w = window {
                w.delegate = nil
                w.close()
                window = nil
            }
        }

        /// 用户手动关演示窗 → 彻底中断流程(用户要求 2026-06-19:关任一窗口=硬中断,别再续/重弹)。
        /// 判定"是用户关的"靠 `isPresented==true`:大脑/代码主动 close() 会先把它置 false(那条分支不触发中断,避免误伤正常收尾)。
        func windowWillClose(_ notification: Notification) {
            window = nil
            if controller?.isPresented == true {
                controller?.onUserClosedWindow?()       // → abortActiveFlow(停批量+回合+掐 TTS+设防重弹窗)
                _ = controller?.close()
            }
        }
    }
}

/// 文件预览面板:PDFKit 渲染 PPT/PDF/Word/Excel(office 已转 PDF),大脑经四肢工具翻页/滚动。
struct LingShuPreviewSheet: View {
    @ObservedObject var controller: LingShuPreviewController

    var body: some View {
        VStack(spacing: 0) {
            if !controller.slideshow {   // 全屏演示时隐藏 chrome,只剩满屏幻灯
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .foregroundStyle(Color.lingHolo)
                    Text(controller.title.isEmpty ? "预览" : controller.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    if controller.pageCount > 0, !controller.isHTML {
                        Text("\(controller.pageIndex + 1) / \(controller.pageCount)")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.lingHolo)
                    }
                    Button { _ = controller.setSlideshow(true) } label: {
                        Label("全屏演示", systemImage: "play.rectangle.fill")
                            .font(.system(size: 11.5, weight: .bold))
                    }.buttonStyle(.plain).foregroundStyle(Color.lingHolo)
                    Button { _ = controller.prev() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                    Button { _ = controller.next() } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                    Button { _ = controller.close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.55))
            }

            ZStack(alignment: .bottom) {
                if controller.isHTML {
                    LingShuWebPreviewView(controller: controller)   // HTML 富页面:WKWebView 原样渲染(CSS/JS),JS 滚动
                } else {
                    LingShuPDFView(controller: controller)
                }
                if controller.slideshow {   // 全屏演示底部极简控制条(WPS 式)
                    HStack(spacing: 18) {
                        Button { _ = controller.prev() } label: { Image(systemName: controller.isHTML ? "chevron.up.circle.fill" : "chevron.left.circle.fill") }.buttonStyle(.plain)
                        if !controller.isHTML {
                            Text("\(controller.pageIndex + 1) / \(controller.pageCount)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        Button { _ = controller.next() } label: { Image(systemName: controller.isHTML ? "chevron.down.circle.fill" : "chevron.right.circle.fill") }.buttonStyle(.plain)
                        Button { _ = controller.setSlideshow(false) } label: { Label("退出", systemImage: "xmark").font(.system(size: 11, weight: .bold)) }.buttonStyle(.plain)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 18)
                }
            }
            .frame(minWidth: 720, minHeight: 540)
        }
        .frame(minWidth: controller.slideshow ? nil : 900, maxWidth: .infinity,
               minHeight: controller.slideshow ? nil : 660, maxHeight: .infinity)
        .background(controller.slideshow ? Color.black : Color.lingVoid)
        .background(WindowFullscreenToggler(active: controller.slideshow))
    }
}

/// 把演示窗的"全屏"同步到 `active`。**用窗口撑满整屏(`screen.visibleFrame`)而非原生全屏**(2026-06-17):
/// 原生 `toggleFullScreen` 会另起一个 macOS 全屏 Space → 灵枢本体浮窗就被挡到别的 Space 看不见了,
/// 还在某些组合下黑屏卡死。改成把演示窗 frame 撑到屏幕可见区:幻灯片照样铺满讲解,且**和本体在同一 Space、
/// 本体(.floating)始终浮在演示窗之上可见**;退出还原原窗口大小。演示在独立窗口里,不碰主窗/本体。
private struct WindowFullscreenToggler: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if active {
                if coordinator.savedFrame == nil { coordinator.savedFrame = window.frame }
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true, animate: true)   // 撑满可见区(让本体仍可浮其上)
                }
                // 进全屏放映=占屏演示:必须把演示窗提到所有 app 最前(自主模式 app 在后台时尤其重要),
                // 否则铺满了也压在别的窗后面、用户看不到(用户实测:没全屏置顶)。
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else if let saved = coordinator.savedFrame {
                window.setFrame(saved, display: true, animate: true)   // 还原退出全屏前的窗口大小
                coordinator.savedFrame = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var savedFrame: NSRect? }
}

/// PDFKit PDFView 的 SwiftUI 包装:声明式同步文档/页码,把 PDFView 弱引用回灌给 controller 供命令式滚动。
private struct LingShuPDFView: NSViewRepresentable {
    @ObservedObject var controller: LingShuPreviewController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .black
        controller.pdfView = view
        context.coordinator.loadedRevision = -1
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.pdfView = view
        // 全屏演示=单页满屏(WPS 式),否则连续滚动(看长文档)。
        let wantMode: PDFDisplayMode = controller.slideshow ? .singlePage : .singlePageContinuous
        if view.displayMode != wantMode { view.displayMode = wantMode }
        if context.coordinator.loadedRevision != controller.revision {
            context.coordinator.loadedRevision = controller.revision
            view.document = controller.document
        }
        if let doc = view.document, let page = doc.page(at: controller.pageIndex), view.currentPage != page {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loadedRevision = -1 }
}

/// HTML 富页面预览:WKWebView 原样渲染(保住 CSS/JS/粒子背景),声明式按 revision 重载,弱引用回灌 controller 供 JS 滚动/取文。
/// 用 app 内 web 视图替代"丢去浏览器+计算机控制滚"——滚动确定性、免辅助功能、免浏览器焦点被 orb 挡的问题。
private struct LingShuWebPreviewView: NSViewRepresentable {
    @ObservedObject var controller: LingShuPreviewController

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.setValue(false, forKey: "drawsBackground")   // 透出深色底,富页面深色主题更贴
        controller.webView = view
        context.coordinator.loadedRevision = -1
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        controller.webView = view
        if context.coordinator.loadedRevision != controller.revision, let url = controller.htmlURL {
            context.coordinator.loadedRevision = controller.revision
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())   // 本地 html + 同目录素材(图/css/js)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loadedRevision = -1 }
}
