import SwiftUI
import WebKit
import QuickLookUI

/// 把本地产出物文件渲染进灵枢内预览。HTML 演示页用 WKWebView 直接渲染；
/// 其他文件（PPTX/PDF 等）用系统 QuickLook 预览，或调用系统应用打开。
struct LingShuArtifactPreviewSheet: View {
    let title: String
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss

    private var isWebRenderable: Bool {
        ["html", "htm"].contains(fileURL.pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(Color.lingHolo)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Label("用系统应用打开", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lingHolo.opacity(0.9))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.black.opacity(0.6))

            if isWebRenderable {
                LingShuWebView(fileURL: fileURL)
            } else {
                LingShuQuickLookView(fileURL: fileURL)
            }
        }
        .frame(width: 900, height: 620)
        .background(Color.lingVoid)
    }
}

/// 渲染本地 HTML（含演示页）。允许读取该文件所在目录的同级资源。
struct LingShuWebView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != fileURL {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }
}

/// 系统 QuickLook 预览（PPTX、PDF、图片等）。
struct LingShuQuickLookView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = fileURL as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = fileURL as NSURL
    }
}
