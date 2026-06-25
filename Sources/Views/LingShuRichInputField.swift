import SwiftUI
import AppKit

/// 输入框里光标处正在打的 `@查询`(供 @ 自动补全弹层):`query`=@ 后已打的字(可空),`range`=含 @ 的整段范围(用于补全替换)。
struct LingShuMentionQuery: Equatable {
    let query: String
    let range: NSRange
}

/// **富文本输入框**(对齐 codex 的内嵌标签):基于 NSTextView,把输入里的 `@别名`(已注册 agent / 插件 / 技能)**实时高亮成 token**。
/// SwiftUI 的 TextField/TextEditor 在 macOS 14 不支持内嵌富文本 token,故换成 NSViewRepresentable 自管属性。
/// 文本仍双向绑定到 `state.prompt`(提交/分诊/「+」菜单插入都不变);Return=提交、Shift+Return=换行;空时画占位;粘贴图片走回调。
struct LingShuRichInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// 已知可 @ 的别名(用于高亮判定;调用方缓存,别每次按键读盘)。
    var aliases: [String]
    var accent: Color
    var onSubmit: () -> Void
    var onPasteImage: ((Data) -> Void)?
    /// **@ 自动补全**:光标处的活跃 mention 变化(打 `@c` → query="c";nil=当前不在 mention 里)。驱动 SwiftUI 弹补全列表。
    var onMentionChange: (LingShuMentionQuery?) -> Void = { _ in }
    /// 补全列表打开时的键盘操作(上/下移高亮、回车选中、Esc 关)——由 SwiftUI 侧据当前匹配执行。
    var onMentionMove: (Bool) -> Void = { _ in }   // up=true
    var onMentionCommit: () -> Void = {}
    var onMentionCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = LingShuInputTextView(frame: .zero, textContainer: container)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = NSColor.clear
        tv.textColor = NSColor.white
        tv.insertionPointColor = NSColor(accent)
        tv.font = Self.baseFont
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [NSView.AutoresizingMask.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.placeholderString = placeholder
        tv.onPasteImage = onPasteImage
        tv.string = text

        context.coordinator.textView = tv
        context.coordinator.applyHighlight()
        scrollView.documentView = tv
        // 加进窗口后自动聚焦输入框(launch 即可直接打字,对齐 codex/聊天输入体验)。
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? LingShuInputTextView else { return }
        context.coordinator.parent = self
        tv.placeholderString = placeholder
        tv.onPasteImage = onPasteImage
        // 同步 binding→视图,但**只在真外部变更时**(「+」菜单插入 / 清空 / 程序替换):
        // 快速输入时 SwiftUI 会把**滞后的** binding 值送进来——若 binding 只是视图已打内容的前缀(打字滞后),**绝不覆盖**(以视图为准),
        // 否则会把刚打的几个字吞掉/错位(实测 @Codex 被重复就是这个)。清空(空串)/插入(更长且非前缀)才应用。
        let viewStr = tv.string
        if viewStr != text {
            let isTypingLag = !text.isEmpty && viewStr.hasPrefix(text)
            if !isTypingLag {
                tv.string = text
                context.coordinator.applyHighlight()
                tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))   // 外部插入后光标到末尾
                tv.needsDisplay = true
            }
        }
    }

    static let baseFont = NSFont.systemFont(ofSize: 15.5, weight: .medium)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LingShuRichInputField
        weak var textView: LingShuInputTextView?
        /// 当前是否有 @ 补全弹层打开(由 updateMention 据光标处算出)——决定上下/回车/Esc 是给弹层还是给输入框。
        var mentionActive = false

        init(_ parent: LingShuRichInputField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            applyHighlight()
            updateMention()
            tv.needsDisplay = true   // 重画占位(空/非空切换)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateMention()   // 光标移动也要重算(移出/移入 @ 段)
        }

        // 键盘:补全弹层打开时,上下移高亮 / 回车选中 / Esc 关;否则 Return=提交、Shift+Return=换行。
        func textView(_ tv: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if mentionActive {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):   parent.onMentionMove(true);  return true
                case #selector(NSResponder.moveDown(_:)): parent.onMentionMove(false); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    parent.onMentionCommit(); return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onMentionCancel(); return true
                default: break
                }
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if !NSEvent.modifierFlags.contains(.shift) {
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }

        /// 算光标处的活跃 @mention,回报给 SwiftUI 驱动补全弹层。
        func updateMention() {
            guard let tv = textView else { return }
            let m = Self.activeMention(in: tv.string as NSString, cursorLoc: tv.selectedRange().location)
            mentionActive = (m != nil)
            parent.onMentionChange(m)
        }

        /// 纯函数(可测):光标前最近的、词边界起始的 `@查询`(中间不含空格)→ (query, 含@的范围);不在 mention 里则 nil。
        nonisolated static func activeMention(in s: NSString, cursorLoc: Int) -> LingShuMentionQuery? {
            guard cursorLoc <= s.length, cursorLoc > 0 else { return nil }
            var i = cursorLoc - 1
            while i >= 0 {
                let ch = s.substring(with: NSRange(location: i, length: 1))
                if ch == "@" {
                    let boundaryOK: Bool = (i == 0) || {
                        let p = s.substring(with: NSRange(location: i - 1, length: 1))
                        return [" ", "\n", "\t", "，", ",", "、", "；", ";"].contains(p)
                    }()
                    guard boundaryOK else { return nil }
                    let query = s.substring(with: NSRange(location: i + 1, length: cursorLoc - i - 1))
                    return LingShuMentionQuery(query: query, range: NSRange(location: i, length: cursorLoc - i))
                }
                if [" ", "\n", "\t"].contains(ch) { return nil }   // 空白还没遇到 @ → 不在 mention
                i -= 1
            }
            return nil
        }

        /// 把 `@别名` 高亮成 token(青色字 + 半透明底),其余文本回到基线白字。
        func applyHighlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let accent = NSColor(parent.accent)
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.white, range: full)
            storage.addAttribute(.font, value: LingShuRichInputField.baseFont, range: full)
            for range in Self.mentionRanges(in: tv.string, aliases: parent.aliases) {
                storage.addAttribute(.backgroundColor, value: accent.withAlphaComponent(0.22), range: range)
                storage.addAttribute(.foregroundColor, value: accent, range: range)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15.5, weight: .bold), range: range)
            }
            storage.endEditing()
        }

        /// 找出所有 `@别名` 的字符范围(纯函数,可测):`@` 后紧跟的、命中已知别名(最长匹配)的那段。
        nonisolated static func mentionRanges(in s: String, aliases: [String]) -> [NSRange] {
            guard !aliases.isEmpty, !s.isEmpty else { return [] }
            let ns = s as NSString
            var ranges: [NSRange] = []
            guard let re = try? NSRegularExpression(pattern: "@([\\w\\u4e00-\\u9fa5]+)") else { return [] }
            re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges >= 2 else { return }
                let name = ns.substring(with: m.range(at: 1))
                // 命中的别名取**最长**(避免 "Codex" 命中短别名只高亮一截)。
                let hit = aliases.filter { name == $0 || name.hasPrefix($0) }.max(by: { $0.count < $1.count })
                guard let hit else { return }
                let tokenLen = 1 + (hit as NSString).length   // @ + 别名
                ranges.append(NSRange(location: m.range.location, length: min(tokenLen, m.range.length)))
            }
            return ranges
        }
    }
}

/// 自管占位绘制 + 图片粘贴拦截的 NSTextView。
final class LingShuInputTextView: NSTextView {
    var placeholderString: String = ""
    var onPasteImage: ((Data) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? LingShuRichInputField.baseFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.32)
        ]
        (placeholderString as NSString).draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: attrs
        )
    }

    /// 粘贴图片(Cmd+V)→ 走云视觉解析回调;纯文本/其它仍走默认粘贴。
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let onPasteImage,
           let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onPasteImage(png)
            return
        }
        super.pasteAsPlainText(sender)   // 纯文本粘贴(不带富文本格式,与原 TextField 一致)
    }
}
