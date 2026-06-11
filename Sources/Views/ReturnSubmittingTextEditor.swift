import AppKit
import SwiftUI

struct ReturnSubmittingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var foregroundColor: NSColor
    var fontSize: CGFloat
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScrollElasticity = .allowed

        let textView = SubmittingNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { context.coordinator.submit() }
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = foregroundColor
        textView.insertionPointColor = foregroundColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmittingNSTextView else { return }

        context.coordinator.onSubmit = onSubmit
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = foregroundColor
        textView.insertionPointColor = foregroundColor
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: foregroundColor
        ]

        if textView.string != text {
            let insertionPoint = min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func submit() {
            onSubmit()
        }
    }

    final class SubmittingNSTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let wantsNewLine = flags.contains(.shift) || flags.contains(.option)
            let hasSystemModifier = flags.contains(.command) || flags.contains(.control)

            if isReturn && !hasMarkedText() && !wantsNewLine && !hasSystemModifier {
                onSubmit?()
                return
            }

            super.keyDown(with: event)
        }
    }
}
