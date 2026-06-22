import AppKit
import Carbon.HIToolbox

/// 全局热键(Carbon `RegisterEventHotKey`):**免辅助功能授权、能消费组合键、app 不在前台也触发**。
/// 用于常驻全局入口(默认 ⌥Space 唤起"问/找/做"快速面板)。回调是 C 函数指针(无捕获)→ 用 id→实例表分发。
final class LingShuGlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let handler: () -> Void

    // Carbon 热键回调在主线程(应用事件目标)触发,访问限于主线程 → unsafe 即可(同仓库遥测/不变量模式)。
    nonisolated(unsafe) private static var instances: [UInt32: LingShuGlobalHotKey] = [:]
    private static let signature: OSType = 0x4C53_4831   // 'LSH1'

    /// keyCode 见 `Carbon.HIToolbox` 的 kVK_*(如空格=49);modifiers 用 Carbon 掩码(optionKey/cmdKey/shiftKey/controlKey)。
    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, handler: @escaping () -> Void) {
        self.id = id
        self.handler = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            LingShuGlobalHotKey.instances[hkID.id]?.handler()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)

        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        Self.instances[id] = self
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        Self.instances[id] = nil
    }
}
