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
    @Environment(\.colorScheme) private var colorScheme

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
                    Label(
                        LingShuLanguagePreferenceStore.localized("用系统应用打开", "Open in Default App"),
                        systemImage: "arrow.up.forward.app"
                    )
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lingHolo.opacity(0.9))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label(
                        LingShuLanguagePreferenceStore.localized("在 Finder 中显示", "Show in Finder"),
                        systemImage: "folder"
                    )
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lingFg.opacity(0.7))
                // **醒目的"关闭"按钮**(原来只有个很淡的小 X,用户找不到)+ Esc 也能关。
                Button(action: close) {
                    Label(
                        LingShuLanguagePreferenceStore.localized("关闭", "Close"),
                        systemImage: "xmark"
                    )
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(toolbarButtonSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lingFg)
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(toolbarSurface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(toolbarStroke)
                    .frame(height: 1)
            }
            .shadow(color: toolbarShadow, radius: colorScheme == .dark ? 0 : 10, y: colorScheme == .dark ? 0 : 1)

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
    }

    private var toolbarSurface: Color {
        colorScheme == .dark ? Color.black.opacity(0.62) : Color.white.opacity(0.96)
    }

    private var toolbarButtonSurface: Color {
        colorScheme == .dark ? Color.lingFg.opacity(0.12) : Color.lingFg.opacity(0.075)
    }

    private var toolbarStroke: Color {
        colorScheme == .dark ? Color.lingFg.opacity(0.14) : Color.lingFg.opacity(0.10)
    }

    private var toolbarShadow: Color {
        colorScheme == .dark ? .clear : Color.black.opacity(0.10)
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
