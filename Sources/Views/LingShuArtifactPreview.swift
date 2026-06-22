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

    @Environment(\.dismiss) private var dismiss

    private var previewKind: LingShuArtifactPreviewKind {
        LingShuArtifactPreviewKind(fileExtension: fileURL.pathExtension)
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
struct LingShuImagePreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = NSImage(contentsOf: fileURL)
        scrollView.documentView = imageView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        imageView.image = NSImage(contentsOf: fileURL)
        imageView.frame = scrollView.bounds
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
