import Foundation
import CoreGraphics
import AppKit

/// 计算机直接操作四肢的工具桥(计划 §9):把 LingShuComputerControl 能力暴露成 agent 工具。
/// **加工具不加控制器**——截屏/列元素/点击/键入/滚动都是大脑可调的手段,要不要用、怎么用由大脑决定。
/// 授权门:`computerControlEnabled`(用户显式开)**或**完整授权独立运行;动作类再加系统辅助功能授权。
@MainActor
extension LingShuState {

    /// 计算机操作是否已授权(总开关 或 完整授权独立运行进行中)。
    var computerControlAuthorized: Bool {
        computerControlEnabled || (autonomousRun.isActive && autonomousRun.permissionLevel == .full)
    }

    /// 打开「计算机直接操作」开关时**立即**向系统申请权限(辅助功能 + 屏幕录制),弹出系统授权框——
    /// 不必等到首次动作才弹(用户反馈:开了开关却没弹系统授权框=根本没申请)。已授权则无弹框。
    /// 由 `computerControlEnabled` 的 didSet 在 false→true 时调用。
    func requestComputerControlPermissions() {
        let ax = LingShuComputerControl.requestAccessibilityTrust()        // 弹辅助功能授权(未授权时)
        let screen = LingShuComputerControl.requestScreenCaptureAccess()   // 弹屏幕录制授权(未授权时)
        let needAX = !ax, needScreen = !screen
        if needAX || needScreen {
            var items: [String] = []
            if needAX { items.append("辅助功能") }
            if needScreen { items.append("屏幕录制") }
            appendTrace(kind: .system, actor: "计算机操作", title: "申请系统权限", detail: "已弹出系统授权框申请:\(items.joined(separator: " + "))。请在框中允许,或到『系统设置 > 隐私与安全性』勾选\"灵枢\"。授权后开关即可生效。")
        } else {
            appendTrace(kind: .system, actor: "计算机操作", title: "权限已具备", detail: "辅助功能 + 屏幕录制均已授权,可直接看屏/点击/键入。")
        }
    }

    /// 授权检查;返回非 nil = 未授权的说明(回给模型,让它要么提示用户开启、要么换别的办法)。
    /// `requiresAccessibility` 的动作类还需系统辅助功能授权(没有则弹一次系统提示)。
    func computerControlGate(requiresAccessibility: Bool) -> String? {
        guard computerControlAuthorized else {
            return "计算机直接操作未授权。请到设置打开『计算机操作』开关,或在完整授权的独立运行下使用,我才能截屏/点击/键入。"
        }
        if requiresAccessibility, !LingShuComputerControl.isAccessibilityTrusted() {
            _ = LingShuComputerControl.requestAccessibilityTrust()
            openAccessibilitySettingsPane()   // 确定性带主人到那一页(比让大脑去截屏找按钮可靠)
            return """
            【终止当前尝试,别再循环】我**没有**辅助功能权限,所以**点不了任何界面元素、也点不了那个系统授权弹窗本身**——
            点系统授权弹窗本来就需要这个权限,我去点=鸡生蛋蛋生鸡的死循环。**绝不要再 screen_capture / list_ui_elements / click 去找那个弹窗自己点**。
            正确做法只有一个:**口头让主人手动授权**——我已弹出系统提示并打开了『系统设置 > 隐私与安全性 > 辅助功能』,请主人在那里把"灵枢"勾上(若已勾上却仍无效=开发期重打包导致旧签名失配:把"灵枢"那行**关掉再打开**,或减号删掉再加号把 \(Bundle.main.bundlePath) 加回来,然后重启灵枢)。勾好后跟我说一声我再试。**这一步交给主人,我做不了,现在就把这话告诉主人、停下别再试。**
            """
        }
        return nil
    }

    /// 确定性打开『系统设置 > 隐私与安全性 > 辅助功能』面板(被要求授权时带主人直达,免大脑徒劳截屏找)。
    func openAccessibilitySettingsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 全部计算机操作工具。始终挂在会话上(授权在 call-time 判,开关即时生效),纯对话/只读模式不挂。
    func computerControlTools() -> [LingShuAgentTool] {
        [screenCaptureTool(), listUIElementsTool(), clickTool(), doubleClickTool(),
         moveMouseTool(), typeTextTool(), pressKeyTool(), scrollTool()]
    }

    private func screenCaptureTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "screen_capture",
            description: "截取当前屏幕并理解其内容(这是你的'眼睛看屏幕')。返回屏幕逻辑尺寸(点)、VL 场景描述、OCR 文本和 PNG 路径。要操作界面前先截屏看清,坐标用**点、左上原点**。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: false) }) { return gate }
            guard let path = LingShuComputerControl.captureScreen() else {
                return "截屏失败(可能缺少屏幕录制授权:系统设置 > 隐私与安全性 > 屏幕录制 勾选\"灵枢\")。"
            }
            let size = LingShuComputerControl.mainScreenSize()
            // 工具回给模型的 PNG 路径始终是**原图**(下游真要细节时可再读),只在 VL 上送时按需缩图。
            let header = "已截屏:\(path)\n屏幕逻辑尺寸:\(Int(size.width)) x \(Int(size.height)) 点(点击用点坐标,左上为原点)。"
            let client = await MainActor.run(body: { self.cloudPerceptionClient })
            guard let client else {
                return header + "\n(视觉理解不可用,仅返回截图路径——可用 list_ui_elements 取可点元素坐标。)"
            }
            if let desc = await Self.analyzeScreenForControl(client: client, pngPath: path) {
                return header + desc
            }
            return header + "\n(VL 解析未返回;可用 list_ui_elements 取可点元素坐标。)"
        }
    }

    private func listUIElementsTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "list_ui_elements",
            description: "列出最前台 App 里可交互的 UI 元素(按钮/菜单项/输入框/链接等)及其屏幕坐标(点)。**精确点击的首选**:拿到\"按钮'允许' @ (640,480)\"后直接 click 它的中心,比从截图猜坐标可靠。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            let elements = LingShuComputerControl.actionableElements()
            guard !elements.isEmpty else { return "没列到可交互元素(可能该 App 不暴露辅助功能信息,或当前没有前台窗口)。可改用 screen_capture 看屏。" }
            let lines = elements.map { e in
                "\(Self.uiRoleLabel(e.role)) \"\(e.title)\" @ (\(Int(e.center.x)),\(Int(e.center.y))) [\(Int(e.frame.width))x\(Int(e.frame.height))]"
            }
            return "前台可交互元素(点其中心坐标即可点击):\n" + lines.joined(separator: "\n")
        }
    }

    private func clickTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "click",
            description: "在屏幕坐标(点,左上原点)点击鼠标。right=true 为右键。坐标从 list_ui_elements 或 screen_capture 得到。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"},\"right\":{\"type\":\"boolean\",\"description\":\"是否右键,默认 false\"}},\"required\":[\"x\",\"y\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            let args = Self.parseArgs(argsJSON)
            guard let p = Self.point(from: args) else { return "需要数值 x、y 坐标。" }
            let right = (args["right"] ?? "false").lowercased() == "true"
            LingShuComputerControl.click(at: p, rightButton: right)
            return "已在 (\(Int(p.x)),\(Int(p.y))) \(right ? "右键" : "")点击。"
        }
    }

    private func doubleClickTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "double_click",
            description: "在屏幕坐标(点)双击鼠标左键(打开文件/进入等)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"}},\"required\":[\"x\",\"y\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let p = Self.point(from: Self.parseArgs(argsJSON)) else { return "需要数值 x、y 坐标。" }
            LingShuComputerControl.doubleClick(at: p)
            return "已在 (\(Int(p.x)),\(Int(p.y))) 双击。"
        }
    }

    private func moveMouseTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "move_mouse",
            description: "把鼠标移动到屏幕坐标(点),不点击(用于悬停/定位)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"}},\"required\":[\"x\",\"y\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let p = Self.point(from: Self.parseArgs(argsJSON)) else { return "需要数值 x、y 坐标。" }
            LingShuComputerControl.moveMouse(to: p)
            return "鼠标已移到 (\(Int(p.x)),\(Int(p.y)))。"
        }
    }

    private func typeTextTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "type_text",
            description: "在当前焦点处键入文本(支持中文/任意字符)。先点好输入框再键入。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            let text = Self.jsonField(argsJSON, "text") ?? ""
            guard !text.isEmpty else { return "没有要键入的文本。" }
            LingShuComputerControl.typeText(text)
            return "已键入:\(text.prefix(40))"
        }
    }

    private func pressKeyTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "press_key",
            description: "按一个键或组合键,如 \"return\"、\"esc\"、\"tab\"、\"cmd+c\"、\"cmd+shift+4\"、\"down\"。任意文字用 type_text。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"keys\":{\"type\":\"string\",\"description\":\"键名或组合,如 cmd+c\"}},\"required\":[\"keys\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            let keys = Self.jsonField(argsJSON, "keys") ?? ""
            guard !keys.isEmpty else { return "没有指定按键。" }
            return LingShuComputerControl.pressKey(keys) ? "已按下:\(keys)" : "无法识别按键组合:\(keys)(任意文字请用 type_text)。"
        }
    }

    private func scrollTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "scroll",
            description: "滚动滚轮。dy 正=向上、负=向下;dx 正=向右、负=向左(行数)。滚动前可先 move_mouse 到目标区域。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"dy\":{\"type\":\"number\"},\"dx\":{\"type\":\"number\"}},\"required\":[\"dy\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            let args = Self.parseArgs(argsJSON)
            let dy = Int32(Double(args["dy"] ?? "0") ?? 0)
            let dx = Int32(Double(args["dx"] ?? "0") ?? 0)
            LingShuComputerControl.scroll(dy: dy, dx: dx)
            return "已滚动 dy=\(dy) dx=\(dx)。"
        }
    }

    // MARK: - screen_capture 的 VL 上送(缩图兜底)

    /// VL 上送原图的体积上限(字节):超过此值的 PNG 直接走缩图,免去一次几乎必败、且上游会**连续重试 3 次**
    /// 才超时的昂贵往返(全屏 Retina PNG ~4MB 远超此线;非 Retina/小窗口/局部内容常 <1MB,可原图直传保细节)。
    nonisolated static let screenCaptureOriginalByteCeiling = 1_000_000

    /// 是否可把原图直接上送 VL(体积够小才行)。纯函数,便于单测。
    nonisolated static func shouldSendOriginalScreenshot(
        pngByteCount: Int,
        ceiling: Int = screenCaptureOriginalByteCeiling
    ) -> Bool {
        pngByteCount > 0 && pngByteCount <= ceiling
    }

    /// `screen_capture` 的 VL 理解策略:这工具是给大脑「看清屏幕后精确点击/输入」用的,缩太狠会丢 UI 细节,
    /// 故**体积安全时优先原图**;原图过大(`shouldSendOriginalScreenshot` 判否)或原图调用失败时,**自动缩到
    /// 1600 长边 JPEG q0.7 重试一次**——既规避「全屏 Retina PNG ~4MB → 网关上游连续 3 次失败 → HTTP 500」
    /// (见架构速查手册「周期感知 VL 必须缩图」不变量),又比周期感知的 1280/q0.6 保留更多可操作细节。
    /// 返回拼好的【屏幕描述】片段(含 OCR + 操作提示);两条路径都拿不到返回 nil 交由上层兜底。
    nonisolated static func analyzeScreenForControl(
        client: LingShuCloudPerceptionClient,
        pngPath: String
    ) async -> String? {
        let prompt = "描述这个电脑屏幕上有什么:主要区域、可点的按钮/菜单/输入框及其大致位置,以及屏幕上的文字。"
        // 第一遍:体积安全的原图(保最大细节)。
        if let data = FileManager.default.contents(atPath: pngPath),
           shouldSendOriginalScreenshot(pngByteCount: data.count),
           let desc = await analyzeImageForControl(client: client, base64: data.base64EncodedString(), prompt: prompt) {
            return desc
        }
        // 第二遍:缩到 1600 长边 JPEG q0.7(规避上游 500,仍保够判断的 UI 细节)。
        if let b64 = LingShuComputerControl.downscaledJPEGBase64(pngPath: pngPath, maxDimension: 1600, quality: 0.7),
           let desc = await analyzeImageForControl(client: client, base64: b64, prompt: prompt) {
            return desc
        }
        return nil
    }

    /// 调一次 VL 并把结果拼成给模型读的【屏幕描述】片段;抛错或 `success=false` 返回 nil(交由上层重试/兜底)。
    private nonisolated static func analyzeImageForControl(
        client: LingShuCloudPerceptionClient,
        base64: String,
        prompt: String
    ) async -> String? {
        guard let r = try? await client.analyzeImage(imageBase64: base64, prompt: prompt, includeGrounding: false),
              r.success else { return nil }
        let ocr = r.ocrTexts.prefix(20).joined(separator: " | ")
        return "\n【屏幕描述】\(r.semanticSuggestions.prefix(600))"
            + (ocr.isEmpty ? "" : "\n【屏上文字】\(ocr.prefix(600))")
            + "\n提示:要精确点击,调 list_ui_elements 拿元素中心坐标更可靠。"
    }

    // MARK: - 纯工具(可测)

    /// 从工具参数里取坐标点(x/y 为数值字符串)。任一缺失/非数值返回 nil。
    nonisolated static func point(from args: [String: String]) -> CGPoint? {
        guard let xs = args["x"], let ys = args["y"], let x = Double(xs), let y = Double(ys) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// AX 角色 → 简短中文标签(给模型读着顺)。
    nonisolated static func uiRoleLabel(_ role: String) -> String {
        switch role {
        case "AXButton": return "按钮"
        case "AXMenuItem", "AXMenuBarItem": return "菜单项"
        case "AXCheckBox": return "复选框"
        case "AXRadioButton": return "单选"
        case "AXTextField", "AXTextArea": return "输入框"
        case "AXLink": return "链接"
        case "AXPopUpButton", "AXComboBox": return "下拉框"
        case "AXTab": return "标签页"
        case "AXSlider": return "滑块"
        case "AXSegmentedControl": return "分段控件"
        case "AXCell": return "单元格"
        case "AXDisclosureTriangle": return "展开三角"
        default: return role
        }
    }

    /// 计算机操作工具显示名(任务窗口/气泡进展用)。
    nonisolated static func computerToolDisplayName(_ tool: String) -> String? {
        switch tool {
        case "screen_capture": return "截屏看屏"
        case "list_ui_elements": return "列界面元素"
        case "click": return "点击"
        case "double_click": return "双击"
        case "move_mouse": return "移动鼠标"
        case "type_text": return "键入文本"
        case "press_key": return "按键"
        case "scroll": return "滚动"
        default: return nil
        }
    }
}
