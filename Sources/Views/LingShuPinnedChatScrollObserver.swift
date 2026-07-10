import AppKit
import SwiftUI

/// 聊天滚动区的“贴底跟随”判定。独立成纯函数,便于覆盖翻页方向和阈值边界。
enum LingShuChatScrollPinning {
    nonisolated static func isAtBottom(
        documentBounds: CGRect,
        visibleBounds: CGRect,
        documentIsFlipped: Bool,
        threshold: CGFloat = 28
    ) -> Bool {
        guard documentBounds.height > visibleBounds.height + threshold else { return true }
        if documentIsFlipped {
            return documentBounds.maxY - visibleBounds.maxY <= threshold
        }
        return visibleBounds.minY - documentBounds.minY <= threshold
    }
}

/// 观察 SwiftUI `ScrollView` 背后的 `NSScrollView`：
/// - 用户在底部时,documentView 因流式回复变高后立即同步到底部；
/// - 用户主动向上滚后,保持当前位置,不被新内容拽回；
/// - 用户自行滚回底部后自动恢复跟随。
struct LingShuPinnedChatScrollObserver: NSViewRepresentable {
    var threshold: CGFloat = 28

    func makeCoordinator() -> Coordinator {
        Coordinator(threshold: threshold)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.threshold = threshold
        if context.coordinator.scrollView == nil {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.attach(from: nsView)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate weak var scrollView: NSScrollView?
        fileprivate var threshold: CGFloat
        private weak var documentView: NSView?
        private var lastDocumentHeight: CGFloat = 0
        private var wasPinnedToBottom = true
        private var attachAttempts = 0

        init(threshold: CGFloat) {
            self.threshold = threshold
        }

        func attach(from probe: NSView) {
            guard scrollView == nil else { return }
            guard let scroll = probe.enclosingScrollView ?? Self.findScrollView(above: probe) else {
                attachAttempts += 1
                guard attachAttempts <= 8 else { return }
                DispatchQueue.main.async { [weak self, weak probe] in
                    guard let self, let probe else { return }
                    self.attach(from: probe)
                }
                return
            }
            attachAttempts = 0
            scrollView = scroll
            documentView = scroll.documentView
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            lastDocumentHeight = scroll.documentView?.bounds.height ?? 0
            wasPinnedToBottom = isCurrentlyPinned(in: scroll)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
            if let documentView = scroll.documentView {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(documentFrameDidChange),
                    name: NSView.frameDidChangeNotification,
                    object: documentView
                )
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
            documentView = nil
        }

        @objc private func clipBoundsDidChange() {
            guard let scrollView else { return }
            wasPinnedToBottom = isCurrentlyPinned(in: scrollView)
        }

        @objc private func documentFrameDidChange() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let newHeight = document.bounds.height
            let heightChanged = abs(newHeight - lastDocumentHeight) > 0.5
            lastDocumentHeight = newHeight
            guard heightChanged else { return }

            if wasPinnedToBottom {
                scrollToBottom(scrollView, document: document)
                wasPinnedToBottom = true
            } else {
                wasPinnedToBottom = isCurrentlyPinned(in: scrollView)
            }
        }

        private func isCurrentlyPinned(in scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return true }
            return LingShuChatScrollPinning.isAtBottom(
                documentBounds: document.bounds,
                visibleBounds: scroll.contentView.bounds,
                documentIsFlipped: document.isFlipped,
                threshold: threshold
            )
        }

        private func scrollToBottom(_ scroll: NSScrollView, document: NSView) {
            let clip = scroll.contentView
            let y: CGFloat
            if document.isFlipped {
                y = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            } else {
                y = document.bounds.minY
            }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }

        private static func findScrollView(above view: NSView) -> NSScrollView? {
            var current = view.superview
            while let candidate = current {
                if let scroll = candidate as? NSScrollView { return scroll }
                current = candidate.superview
            }
            return nil
        }
    }
}
