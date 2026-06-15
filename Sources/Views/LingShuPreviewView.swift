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
private struct WindowFullscreenToggler: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let isFull = window.styleMask.contains(.fullScreen)
            if active != isFull { window.toggleFullScreen(nil) }
        }
    }
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
