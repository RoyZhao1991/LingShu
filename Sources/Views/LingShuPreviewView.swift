import SwiftUI
import PDFKit

/// 把预览面板作为 sheet 挂到根视图(观察 controller 的 isPresented,大脑 open_preview 即弹出)。
struct LingShuPreviewHost: View {
    @ObservedObject var controller: LingShuPreviewController
    var body: some View {
        Color.clear.sheet(isPresented: $controller.isPresented) {
            LingShuPreviewSheet(controller: controller)
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
                    if controller.pageCount > 0 {
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
                LingShuPDFView(controller: controller)
                if controller.slideshow {   // 全屏演示底部极简控制条(WPS 式)
                    HStack(spacing: 18) {
                        Button { _ = controller.prev() } label: { Image(systemName: "chevron.left.circle.fill") }.buttonStyle(.plain)
                        Text("\(controller.pageIndex + 1) / \(controller.pageCount)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Button { _ = controller.next() } label: { Image(systemName: "chevron.right.circle.fill") }.buttonStyle(.plain)
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

/// 把承载窗口的全屏状态同步到 `active`(全屏演示进/出)。
/// 坑:预览是 `.sheet`,sheet 窗口默认不带 `.fullScreenPrimary`→`toggleFullScreen` 静默无效(实测"全屏演示"没放大)。
/// 修:进全屏前先补上 `.fullScreenPrimary`+`.resizable` 让原生全屏生效;短延时后若仍没进全屏(sheet 顽抗),
/// **兜底把窗口 frame 撑到整屏**(`screen.frame`)——保证幻灯片一定被放大铺满,达到"演示模式放大讲解"的效果。
private struct WindowFullscreenToggler: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let isFull = window.styleMask.contains(.fullScreen)
            if active, !isFull {
                if coordinator.savedFrame == nil { coordinator.savedFrame = window.frame }
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.styleMask.insert(.resizable)
                window.toggleFullScreen(nil)
                // 兜底:sheet 可能拒绝原生全屏 → 0.35s 后还没全屏就把 frame 撑满整屏。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard active, !window.styleMask.contains(.fullScreen),
                          let screen = window.screen ?? NSScreen.main else { return }
                    window.setFrame(screen.frame, display: true, animate: true)
                }
            } else if !active {
                if isFull { window.toggleFullScreen(nil) }
                if let saved = coordinator.savedFrame {   // 还原退出前的窗口大小
                    window.setFrame(saved, display: true, animate: true)
                    coordinator.savedFrame = nil
                }
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
