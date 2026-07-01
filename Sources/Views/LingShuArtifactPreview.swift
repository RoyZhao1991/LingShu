import AppKit
import AVKit
import QuickLookUI
import SwiftUI
import WebKit

/// 把本地产出物文件渲染进灵枢内预览。
/// HTML 用 WKWebView；图片、音频、视频走本机原生预览；其他文件走 QuickLook。
struct LingShuArtifactPreviewSheet: View {
    let title: String
    let fileURL: URL
    /// **可靠关闭(2026-06-29 修"图片预览没关闭按钮/关不掉")**:调用方传进来,直接翻 `isPresented` 绑定关掉——
    /// 不只依赖嵌套 sheet 里常失灵的 `@Environment(\.dismiss)`。给了 onClose 就用它,没给才回退 dismiss()。
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var previewKind: LingShuArtifactPreviewKind {
        LingShuArtifactPreviewKind(fileExtension: fileURL.pathExtension)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(Color.lingHolo)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lingFg)
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
                .foregroundStyle(Color.lingFg.opacity(0.7))
                // **醒目的"关闭"按钮**(原来只有个很淡的小 X,用户找不到)+ Esc 也能关。
                Button(action: close) {
                    Label("关闭", systemImage: "xmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.lingFg.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lingFg)
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(Color.black.opacity(0.6))

            switch previewKind {
            case .web:
                LingShuWebView(fileURL: fileURL)
            case .image:
                LingShuImagePreviewView(fileURL: fileURL)
            case .media:
                LingShuMediaPreviewView(fileURL: fileURL)
            case .quickLook:
                LingShuQuickLookView(fileURL: fileURL)
            }
        }
        .frame(width: 900, height: 620)
        .background(Color.lingVoid)
        .onExitCommand(perform: close)   // Esc 关闭(嵌套窗口里 dismiss 失灵时的兜底)
        // **悬浮关闭钮(2026-06-29 修"关闭胶囊在哪/没关闭按钮")**:顶部头条在嵌套 sheet 里可能被裁掉/看不见,
        // 这里在预览右上角再钉一个**绝对定位、永远在最上层**的圆形 ✕,无论头条渲染与否都能一眼看到、点得到。
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.lingFg)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.black.opacity(0.7)))
                    .overlay(Circle().stroke(Color.lingFg.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(14)
            .help("关闭预览（Esc）")
        }
    }
}

/// 无外壳的 inline 产出物渲染(供文件树/多模态面板就地嵌入;复用类型判定 + 各渲染器,不带 Sheet 的固定尺寸/工具栏)。
struct LingShuInlineArtifactPreview: View {
    let fileURL: URL
    var body: some View {
        switch LingShuArtifactPreviewKind(fileExtension: fileURL.pathExtension) {
        case .web: LingShuWebView(fileURL: fileURL)
        case .image: LingShuImagePreviewView(fileURL: fileURL)
        case .media: LingShuMediaPreviewView(fileURL: fileURL)
        case .quickLook: LingShuQuickLookView(fileURL: fileURL)
        }
    }
}

private enum LingShuArtifactPreviewKind {
    case web
    case image
    case media
    case quickLook

    init(fileExtension: String) {
        let ext = fileExtension.lowercased()
        if ["html", "htm"].contains(ext) {
            self = .web
        } else if ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tif", "tiff"].contains(ext) {
            self = .image
        } else if ["mp3", "m4a", "wav", "aiff", "aac", "flac", "mov", "mp4", "m4v", "avi", "mkv"].contains(ext) {
            self = .media
        } else {
            self = .quickLook
        }
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

/// 本地图片预览，避免把图片上传到云端或外部服务。
/// **修(2026-06-28)**:原来用 NSScrollView + documentView,documentView 的 frame 取 `scrollView.bounds`——布局前 bounds=0 →
/// 文档视图塌成 0 尺寸 → 图不显示(用户实测:预览框黑屏)。改用**直接铺满的 NSImageView**(SwiftUI 经 representable 给它父级尺寸),稳。
struct LingShuImagePreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        v.image = NSImage(contentsOf: fileURL)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        v.image = NSImage(contentsOf: fileURL)
    }
}

/// 本地音视频预览，保留系统播放控件，不自动播放。
struct LingShuMediaPreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = context.coordinator.player(for: fileURL)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = context.coordinator.player(for: fileURL)
    }

    final class Coordinator {
        private var currentURL: URL?
        private var currentPlayer: AVPlayer?

        func player(for url: URL) -> AVPlayer {
            if currentURL != url {
                currentURL = url
                currentPlayer = AVPlayer(url: url)
            }
            return currentPlayer ?? AVPlayer(url: url)
        }
    }
}
