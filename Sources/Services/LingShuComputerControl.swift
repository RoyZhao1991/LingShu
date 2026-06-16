import AppKit
import CoreGraphics
import ApplicationServices

/// 计算机直接操作的**能力层**(四肢,非控制器):截屏 / 鼠标 / 键盘 / 滚动 / 列出可点 UI 元素(辅助功能 AX)。
/// 纯能力封装,不含决策——决策留给大脑(模型经 LingShuState+ComputerControl 的工具按需调用)。
///
/// 权限:动作类(点击/键入/滚动)需**辅助功能(Accessibility)**授权(`isAccessibilityTrusted`);
/// 截屏需**屏幕录制**授权(app 已为会议/视觉申请)。坐标统一用**点(point)、左上原点**(CGEvent/AX 同口径)。
enum LingShuComputerControl {

    // MARK: - 权限

    /// 是否已获辅助功能授权(发送鼠标/键盘事件、读 AX 树都需要)。
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 弹系统辅助功能授权提示(用户去『系统设置 > 隐私与安全性 > 辅助功能』勾选)。返回当前是否已信任。
    @discardableResult
    static func requestAccessibilityTrust() -> Bool {
        // 直接用 key 的字面值,避开 Swift 6 对全局 var kAXTrustedCheckOptionPrompt 的并发安全报错。
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// 是否已获屏幕录制授权(截屏需要)。
    static func isScreenCaptureTrusted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// 弹屏幕录制授权框(截屏需要)。已授权则无操作;首次调用触发系统授权请求。返回是否已授权。
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - 屏幕

    /// 主屏逻辑尺寸(点)。模型用点坐标点击(非像素),避免 Retina 2x 偏移。
    static func mainScreenSize() -> CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    /// 截屏到临时 PNG,返回路径(失败 nil)。`-x` 静音、`-t png`。需屏幕录制授权。
    static func captureScreen() -> String? {
        let path = NSTemporaryDirectory() + "lingshu-screen-\(Int(Date().timeIntervalSince1970)).png"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-t", "png", path]
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - 鼠标

    static func moveMouse(to point: CGPoint) {
        postMouse(type: .mouseMoved, point: point, button: .left)
    }

    static func click(at point: CGPoint, rightButton: Bool = false) {
        let button: CGMouseButton = rightButton ? .right : .left
        let down: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        postMouse(type: down, point: point, button: button)
        postMouse(type: up, point: point, button: button)
    }

    static func doubleClick(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { return }
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down.setIntegerValueField(.mouseEventClickState, value: 2)
        up?.setIntegerValueField(.mouseEventClickState, value: 2)
        down.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func drag(from: CGPoint, to: CGPoint) {
        postMouse(type: .leftMouseDown, point: from, button: .left)
        postMouse(type: .leftMouseDragged, point: to, button: .left)
        postMouse(type: .leftMouseUp, point: to, button: .left)
    }

    private static func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - 滚动

    /// 滚动(行数,正=上/右,负=下/左)。
    static func scroll(dy: Int32, dx: Int32 = 0) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - 键盘

    /// 输入任意文本(含中文/emoji)——用 Unicode 字符串注入,不依赖键位映射。
    static func typeText(_ text: String) {
        for scalarChunk in text.unicodeScalars.chunked(into: 20) {
            let s = String(String.UnicodeScalarView(scalarChunk))
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            var utf16 = Array(s.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// 按一个键或组合键(如 "return"、"cmd+c"、"cmd+shift+4")。无法解析返回 false。
    @discardableResult
    static func pressKey(_ combo: String) -> Bool {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let keyCode = keyCodeMap[keyName] else { return false }
        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return false
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// 键名 → 虚拟键码(常用键 + 字母数字,供组合快捷键;任意文本用 typeText)。
    static let keyCodeMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "comma": 43, "period": 47, "slash": 44, "minus": 27, "equal": 24
    ]

    // MARK: - 可点 UI 元素(辅助功能 AX)——可靠点击的关键:给大脑「元素+坐标」列表

    struct UIElement {
        var role: String
        var title: String
        var center: CGPoint
        var frame: CGRect
    }

    /// 列出最前台 app 里**可交互**元素(按钮/菜单项/输入框/链接等)+ 屏幕坐标(点)。
    /// 大脑据此精确点击("点 frame 中心"),比从截屏猜坐标可靠得多。limit 控数量防爆。
    static func actionableElements(limit: Int = 60) -> [UIElement] {
        guard isAccessibilityTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var out: [UIElement] = []
        walk(axApp, depth: 0, maxDepth: 18, out: &out, limit: limit)
        return out
    }

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXLink", "AXPopUpButton", "AXComboBox",
        "AXTab", "AXSlider", "AXDisclosureTriangle", "AXSegmentedControl", "AXCell"
    ]

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, out: inout [UIElement], limit: Int) {
        guard depth <= maxDepth, out.count < limit else { return }
        if let role = axString(element, kAXRoleAttribute), actionableRoles.contains(role),
           let frame = axFrame(element), frame.width > 1, frame.height > 1 {
            let title = axString(element, kAXTitleAttribute)
                ?? axString(element, kAXDescriptionAttribute)
                ?? axString(element, kAXValueAttribute)
                ?? ""
            out.append(UIElement(role: role, title: String(title.prefix(60)),
                                 center: CGPoint(x: frame.midX, y: frame.midY), frame: frame))
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children where out.count < limit {
            walk(child, depth: depth + 1, maxDepth: maxDepth, out: &out, limit: limit)
        }
    }

    private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        return nil
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

private extension Collection {
    func chunked(into size: Int) -> [[Element]] {
        Array(self).chunked(into: size)
    }
}
