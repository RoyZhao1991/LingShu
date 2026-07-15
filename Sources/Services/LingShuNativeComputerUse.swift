import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A model-neutral description of a running macOS app. The native Computer Use
/// runtime accepts the name, bundle id, executable path, or pid as its target.
struct LingShuComputerAppSummary: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String
    let executablePath: String
    let isActive: Bool

    var stableTarget: String {
        bundleIdentifier.isEmpty ? String(pid) : bundleIdentifier
    }
}

/// One addressable node in an accessibility snapshot. `index` is intentionally
/// scoped to one snapshot; callers must refresh state after every action.
struct LingShuComputerStateNode: Equatable, Sendable {
    let index: Int
    let role: String
    let subrole: String
    let title: String
    let value: String
    let help: String
    let identifier: String
    let enabled: Bool
    let focused: Bool
    let valueSettable: Bool
    let frame: CGRect?
    let actions: [String]

    var label: String {
        let candidates = [title, value, help, identifier]
        var seen: Set<String> = []
        return candidates.filter { value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !seen.contains(clean) else { return false }
            seen.insert(clean)
            return true
        }.joined(separator: " | ")
    }

    var semanticSignature: String {
        let rect: String
        if let frame {
            rect = "\(Int(frame.origin.x.rounded())),\(Int(frame.origin.y.rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
        } else {
            rect = "-"
        }
        return [role, subrole, title, value, help, identifier, enabled ? "1" : "0", focused ? "1" : "0", rect]
            .joined(separator: "\u{1f}")
    }

    var modelLine: String {
        var parts = ["[#\(index)]", LingShuNativeComputerUsePolicy.roleLabel(role)]
        if !label.isEmpty { parts.append("\"\(label)\"") }
        if focused { parts.append("focused") }
        if !enabled { parts.append("disabled") }
        if valueSettable { parts.append("settable") }
        if let frame {
            parts.append("frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)))")
        }
        if !actions.isEmpty { parts.append("actions=[\(actions.joined(separator: ","))]") }
        return parts.joined(separator: " ")
    }
}

struct LingShuComputerStateDiff: Equatable, Sendable {
    let previousSnapshotID: String?
    let changed: Bool
    let added: [String]
    let removed: [String]
}

struct LingShuComputerObservation: Equatable, Sendable {
    let snapshotID: String
    let app: LingShuComputerAppSummary
    let windowTitle: String
    let screenshotPath: String?
    let nodes: [LingShuComputerStateNode]
    let truncated: Bool
    let diff: LingShuComputerStateDiff

    var modelText: String {
        var lines = [
            "应用状态快照 snapshot_id=\(snapshotID)",
            "app=\(app.name) bundle_id=\(app.bundleIdentifier.isEmpty ? "(无)" : app.bundleIdentifier) pid=\(app.pid)\(app.isActive ? " active=true" : "")",
            "window=\(windowTitle.isEmpty ? "(未取到标题)" : windowTitle)",
            screenshotPath.map { "screenshot=\($0)" } ?? "screenshot=(未生成；仍可使用辅助功能语义树)",
        ]
        if let previous = diff.previousSnapshotID {
            lines.append("与上一快照 \(previous) 比较：\(diff.changed ? "界面有变化" : "未观察到语义变化")")
            if !diff.added.isEmpty { lines.append("新增：\(diff.added.joined(separator: "；"))") }
            if !diff.removed.isEmpty { lines.append("消失：\(diff.removed.joined(separator: "；"))") }
        }
        lines.append("元素（后续动作必须同时携带本 snapshot_id 和 #index）：")
        lines.append(contentsOf: nodes.map(\.modelLine))
        if nodes.isEmpty { lines.append("(该应用当前未暴露可读的辅助功能元素)") }
        if truncated { lines.append("(元素过多，已截断；可提高 max_elements 后重新观察)") }
        return lines.joined(separator: "\n")
    }
}

/// Pure policy helpers kept outside the runtime so matching, diffs, and safety
/// classification can be tested without desktop permissions.
enum LingShuNativeComputerUsePolicy {
    static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXLink", "AXPopUpButton", "AXComboBox",
        "AXTab", "AXSlider", "AXDisclosureTriangle", "AXSegmentedControl", "AXCell",
        "AXRow", "AXOutlineRow", "AXIncrementor", "AXColorWell"
    ]

    private static let contextRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDialog", "AXToolbar", "AXGroup",
        "AXStaticText", "AXHeading", "AXImage", "AXTable", "AXOutline", "AXWebArea"
    ]

    static func shouldExpose(role: String, label: String, actions: [String], valueSettable: Bool) -> Bool {
        actionableRoles.contains(role)
            || contextRoles.contains(role) && !label.isEmpty
            || !actions.isEmpty
            || valueSettable
    }

    static func roleLabel(_ role: String) -> String {
        switch role {
        case "AXApplication": return "应用"
        case "AXWindow": return "窗口"
        case "AXSheet": return "表单"
        case "AXDialog": return "对话框"
        case "AXButton": return "按钮"
        case "AXMenuItem", "AXMenuBarItem": return "菜单项"
        case "AXCheckBox": return "复选框"
        case "AXRadioButton": return "单选"
        case "AXTextField", "AXTextArea": return "输入框"
        case "AXStaticText": return "文本"
        case "AXHeading": return "标题"
        case "AXLink": return "链接"
        case "AXPopUpButton", "AXComboBox": return "下拉框"
        case "AXTab": return "标签页"
        case "AXSlider": return "滑块"
        case "AXSegmentedControl": return "分段控件"
        case "AXTable": return "表格"
        case "AXRow", "AXOutlineRow": return "行"
        case "AXCell": return "单元格"
        case "AXImage": return "图片"
        case "AXToolbar": return "工具栏"
        default: return role
        }
    }

    static func matchApp(query: String, candidates: [LingShuComputerAppSummary]) -> LingShuComputerAppSummary? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, needle != "frontmost", needle != "active" else {
            return candidates.first(where: \.isActive) ?? candidates.first
        }
        if let pid = pid_t(needle), let exactPID = candidates.first(where: { $0.pid == pid }) {
            return exactPID
        }
        func score(_ app: LingShuComputerAppSummary) -> Int {
            let name = app.name.lowercased()
            let bundle = app.bundleIdentifier.lowercased()
            let path = app.executablePath.lowercased()
            if bundle == needle { return 100 }
            if name == needle { return 95 }
            if path == needle { return 90 }
            if bundle.hasSuffix(".\(needle)") { return 85 }
            if bundle.contains(needle) { return 75 }
            if name.contains(needle) { return 70 }
            if path.contains(needle) { return 60 }
            return 0
        }
        let scored: [(app: LingShuComputerAppSummary, score: Int)] = candidates.map { app in
            (app: app, score: score(app))
        }
        return scored.filter { $0.score > 0 }
            .sorted { lhs, rhs in
                lhs.score == rhs.score
                    ? lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
                    : lhs.score > rhs.score
            }
            .first?.app
    }

    static func diff(
        previousSnapshotID: String?,
        previous: [LingShuComputerStateNode],
        current: [LingShuComputerStateNode]
    ) -> LingShuComputerStateDiff {
        guard let previousSnapshotID else {
            return .init(previousSnapshotID: nil, changed: false, added: [], removed: [])
        }
        let old = previous.reduce(into: [String: String]()) { $0[$1.semanticSignature] = concise($1) }
        let new = current.reduce(into: [String: String]()) { $0[$1.semanticSignature] = concise($1) }
        let added = new.keys.filter { old[$0] == nil }.compactMap { new[$0] }.prefix(6)
        let removed = old.keys.filter { new[$0] == nil }.compactMap { old[$0] }.prefix(6)
        return .init(
            previousSnapshotID: previousSnapshotID,
            changed: !added.isEmpty || !removed.isEmpty,
            added: Array(added),
            removed: Array(removed)
        )
    }

    static func requiresExplicitConfirmation(label: String, action: String) -> Bool {
        let text = "\(label) \(action)".lowercased()
        let markers = [
            "付款", "支付", "购买", "下单", "转账", "汇款", "发送", "发布", "提交订单",
            "删除", "永久删除", "清空", "抹掉", "格式化", "卸载", "注销账号", "关闭账户",
            "pay", "purchase", "buy", "checkout", "place order", "transfer", "send", "publish",
            "delete", "remove permanently", "erase", "format", "uninstall", "close account"
        ]
        return markers.contains { text.contains($0) }
    }

    static func redactedValue(
        role: String,
        subrole: String,
        title: String,
        help: String,
        identifier: String,
        value: String
    ) -> String {
        guard !value.isEmpty else { return value }
        let secureRole = "\(role) \(subrole)".lowercased()
        if secureRole.contains("secure") || secureRole.contains("password") {
            return "（敏感内容已隐藏）"
        }
        let isEditableInput = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
        guard isEditableInput else { return value }
        let context = "\(title) \(help) \(identifier)".lowercased()
        let sensitiveMarkers = [
            "密码", "口令", "密钥", "令牌", "凭证", "secret", "password", "passcode",
            "token", "api key", "apikey", "credential", "private key"
        ]
        return sensitiveMarkers.contains(where: context.contains) ? "（敏感内容已隐藏）" : value
    }

    private static func concise(_ node: LingShuComputerStateNode) -> String {
        let text = node.label.isEmpty ? roleLabel(node.role) : "\(roleLabel(node.role)) \"\(node.label)\""
        return String(text.prefix(100))
    }
}

/// Native macOS Computer Use runtime. It operates on app-scoped AX snapshots,
/// keeps element references private, refreshes after every action, and only
/// falls back to coordinates when the target does not expose a semantic action.
@MainActor
final class LingShuNativeComputerUseRuntime {
    static let shared = LingShuNativeComputerUseRuntime()

    private struct CachedSnapshot {
        let observation: LingShuComputerObservation
        let application: NSRunningApplication
        let elements: [Int: AXUIElement]
        let createdAt: Date
    }

    private var snapshots: [String: CachedSnapshot] = [:]
    private var latestSnapshotByPID: [pid_t: String] = [:]
    private let snapshotLifetime: TimeInterval = 5 * 60
    private let snapshotLimit = 16

    private init() {}

    func listAppsText() -> String {
        let apps = runningApps()
        guard !apps.isEmpty else { return "当前没有可控制的图形应用。" }
        let lines = apps.prefix(60).map { app in
            let active = app.isActive ? " active=true" : ""
            return "- \(app.name) | bundle_id=\(app.bundleIdentifier.isEmpty ? "(无)" : app.bundleIdentifier) | pid=\(app.pid)\(active)"
        }
        return "当前运行的图形应用（computer_get_state 的 target 可用名称、bundle_id 或 pid）：\n" + lines.joined(separator: "\n")
    }

    func observe(target: String?, maxElements: Int, includeScreenshot: Bool) -> String {
        let apps = runningApps()
        let query = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let summary = LingShuNativeComputerUsePolicy.matchApp(query: query, candidates: apps),
              let app = NSRunningApplication(processIdentifier: summary.pid) else {
            let available = apps.prefix(12).map(\.name).joined(separator: "、")
            return "没找到目标应用「\(query.isEmpty ? "当前前台应用" : query)」。当前可用：\(available)。先调用 computer_list_apps。"
        }
        return makeObservation(app: app, maxElements: maxElements, includeScreenshot: includeScreenshot).modelText
    }

    func click(
        snapshotID: String,
        index: Int,
        button: String,
        count: Int,
        confirmed: Bool
    ) async -> String {
        switch lookup(snapshotID: snapshotID, index: index) {
        case .failure(let message): return message
        case .success(let snapshot, let element, let node):
            let label = node.label
            guard confirmed || !LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: label, action: "click") else {
                return confirmationRequired(action: "点击", node: node)
            }
            activate(snapshot.application)
            let normalizedButton = button.lowercased()
            let clicks = min(max(count, 1), 2)
            var method = "坐标事件"
            if normalizedButton == "left", clicks == 1,
               node.actions.contains(kAXPressAction),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                method = "辅助功能 AXPress"
            } else if let frame = node.frame {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                if normalizedButton == "right" {
                    LingShuComputerControl.click(at: center, rightButton: true)
                } else if clicks == 2 {
                    LingShuComputerControl.doubleClick(at: center)
                } else {
                    LingShuComputerControl.click(at: center)
                }
            } else {
                return "元素 #\(index) 没有可执行的 AXPress，也没有可用坐标；请刷新状态或换一个父级元素。"
            }
            return await verifiedResult(
                description: "已用\(method)\(clicks == 2 ? "双击" : "点击") #\(index) \(label)",
                before: snapshot
            )
        }
    }

    func setText(snapshotID: String, index: Int, text: String, replace: Bool) async -> String {
        guard !text.isEmpty else { return "没有要输入的文本。" }
        switch lookup(snapshotID: snapshotID, index: index) {
        case .failure(let message): return message
        case .success(let snapshot, let element, let node):
            activate(snapshot.application)
            var method = "键盘输入"
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue,
               AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                method = "辅助功能 AXValue"
            } else if let frame = node.frame {
                LingShuComputerControl.click(at: CGPoint(x: frame.midX, y: frame.midY))
                if replace { _ = LingShuComputerControl.pressKey("cmd+a") }
                LingShuComputerControl.typeText(text)
            } else {
                return "元素 #\(index) 不支持设置值且没有可点击坐标，未输入任何内容。"
            }
            return await verifiedResult(
                description: "已通过\(method)向 #\(index) 输入 \(text.count) 个字符（不在日志回显正文）",
                before: snapshot
            )
        }
    }

    func pressKey(snapshotID: String, index: Int?, keys: String, confirmed: Bool) async -> String {
        guard !keys.isEmpty else { return "没有指定按键。" }
        switch lookupSnapshot(snapshotID: snapshotID) {
        case .failure(let message): return message
        case .success(let snapshot):
            var node: LingShuComputerStateNode?
            if let index {
                guard let cachedNode = snapshot.observation.nodes.first(where: { $0.index == index }) else {
                    return "快照 \(snapshotID) 中没有元素 #\(index)。请刷新 computer_get_state。"
                }
                node = cachedNode
            }
            let label = node?.label ?? snapshot.observation.windowTitle
            guard confirmed || !LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: label, action: keys) else {
                return confirmationRequired(action: "按键 \(keys)", node: node)
            }
            activate(snapshot.application)
            if let index, let element = snapshot.elements[index], let frame = node?.frame {
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                LingShuComputerControl.moveMouse(to: CGPoint(x: frame.midX, y: frame.midY))
            }
            guard LingShuComputerControl.pressKey(keys) else { return "无法识别按键组合：\(keys)。" }
            return await verifiedResult(description: "已按下 \(keys)", before: snapshot)
        }
    }

    func scroll(snapshotID: String, index: Int?, dy: Int32, dx: Int32) async -> String {
        switch lookupSnapshot(snapshotID: snapshotID) {
        case .failure(let message): return message
        case .success(let snapshot):
            activate(snapshot.application)
            if let index {
                guard let node = snapshot.observation.nodes.first(where: { $0.index == index }), let frame = node.frame else {
                    return "快照中没有带坐标的元素 #\(index)。"
                }
                LingShuComputerControl.moveMouse(to: CGPoint(x: frame.midX, y: frame.midY))
            }
            LingShuComputerControl.scroll(dy: dy, dx: dx)
            return await verifiedResult(description: "已滚动 dy=\(dy) dx=\(dx)", before: snapshot)
        }
    }

    func drag(snapshotID: String, fromIndex: Int, toIndex: Int, confirmed: Bool) async -> String {
        switch lookupSnapshot(snapshotID: snapshotID) {
        case .failure(let message): return message
        case .success(let snapshot):
            guard let from = snapshot.observation.nodes.first(where: { $0.index == fromIndex }),
                  let to = snapshot.observation.nodes.first(where: { $0.index == toIndex }),
                  let fromFrame = from.frame, let toFrame = to.frame else {
                return "拖拽起点或终点在该快照中不存在/没有坐标。"
            }
            guard confirmed || !LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: "\(from.label) \(to.label)", action: "drag") else {
                return confirmationRequired(action: "拖拽", node: to)
            }
            activate(snapshot.application)
            LingShuComputerControl.drag(
                from: CGPoint(x: fromFrame.midX, y: fromFrame.midY),
                to: CGPoint(x: toFrame.midX, y: toFrame.midY)
            )
            return await verifiedResult(description: "已从 #\(fromIndex) 拖到 #\(toIndex)", before: snapshot)
        }
    }

    func performAction(snapshotID: String, index: Int, action: String, confirmed: Bool) async -> String {
        switch lookup(snapshotID: snapshotID, index: index) {
        case .failure(let message): return message
        case .success(let snapshot, let element, let node):
            guard let canonical = node.actions.first(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) else {
                return "元素 #\(index) 不支持动作 \(action)。可用动作：\(node.actions.joined(separator: ", "))"
            }
            guard confirmed || !LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: node.label, action: canonical) else {
                return confirmationRequired(action: canonical, node: node)
            }
            activate(snapshot.application)
            let error = AXUIElementPerformAction(element, canonical as CFString)
            guard error == .success else { return "辅助功能动作 \(canonical) 执行失败（AXError=\(error.rawValue)）。" }
            return await verifiedResult(description: "已对 #\(index) 执行 \(canonical)", before: snapshot)
        }
    }

    private enum SnapshotLookup {
        case success(CachedSnapshot)
        case failure(String)
    }

    private enum ElementLookup {
        case success(snapshot: CachedSnapshot, element: AXUIElement, node: LingShuComputerStateNode)
        case failure(String)
    }

    private func lookupSnapshot(snapshotID: String) -> SnapshotLookup {
        pruneSnapshots()
        guard let snapshot = snapshots[snapshotID] else {
            return .failure("快照 \(snapshotID) 已失效或不存在。先调用 computer_get_state 获取最新 snapshot_id。")
        }
        guard !snapshot.application.isTerminated else {
            return .failure("目标应用已经退出。先调用 computer_list_apps。")
        }
        guard latestSnapshotByPID[snapshot.observation.app.pid] == snapshotID else {
            return .failure("快照 \(snapshotID) 不是该应用的最新状态。为避免点错元素，请使用最近一次 computer_get_state 返回的 snapshot_id。")
        }
        return .success(snapshot)
    }

    private func lookup(snapshotID: String, index: Int) -> ElementLookup {
        switch lookupSnapshot(snapshotID: snapshotID) {
        case .failure(let message): return .failure(message)
        case .success(let snapshot):
            guard let element = snapshot.elements[index],
                  let node = snapshot.observation.nodes.first(where: { $0.index == index }) else {
                return .failure("快照 \(snapshotID) 中没有元素 #\(index)。请刷新状态后按新索引操作。")
            }
            guard node.enabled else { return .failure("元素 #\(index) 当前不可用（disabled），未执行。") }
            return .success(snapshot: snapshot, element: element, node: node)
        }
    }

    private func runningApps() -> [LingShuComputerAppSummary] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && ($0.activationPolicy == .regular || $0.processIdentifier == frontmostPID) }
            .map { app in
                LingShuComputerAppSummary(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "未知应用",
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    executablePath: app.executableURL?.path ?? "",
                    isActive: app.processIdentifier == frontmostPID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func makeObservation(app: NSRunningApplication, maxElements: Int, includeScreenshot: Bool) -> LingShuComputerObservation {
        pruneSnapshots()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let appSummary = LingShuComputerAppSummary(
            pid: app.processIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "未知应用",
            bundleIdentifier: app.bundleIdentifier ?? "",
            executablePath: app.executableURL?.path ?? "",
            isActive: app.processIdentifier == frontmostPID
        )
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windowTitle = focusedWindowTitle(axApp)
        let clampedLimit = min(max(maxElements, 20), 160)
        var nodes: [LingShuComputerStateNode] = []
        var refs: [Int: AXUIElement] = [:]
        var visited: Set<CFHashCode> = []
        var reachedLimit = false
        walk(
            axApp,
            depth: 0,
            maxDepth: 22,
            limit: clampedLimit,
            nodes: &nodes,
            refs: &refs,
            visited: &visited,
            reachedLimit: &reachedLimit
        )

        let previousID = latestSnapshotByPID[app.processIdentifier]
        let previousNodes = previousID.flatMap { snapshots[$0]?.observation.nodes } ?? []
        let snapshotID = "cu-\(UUID().uuidString.prefix(8))"
        let diff = LingShuNativeComputerUsePolicy.diff(
            previousSnapshotID: previousID,
            previous: previousNodes,
            current: nodes
        )
        let screenshot = includeScreenshot ? captureApplicationWindow(pid: app.processIdentifier) : nil
        let observation = LingShuComputerObservation(
            snapshotID: snapshotID,
            app: appSummary,
            windowTitle: windowTitle,
            screenshotPath: screenshot,
            nodes: nodes,
            truncated: reachedLimit,
            diff: diff
        )
        snapshots[snapshotID] = CachedSnapshot(observation: observation, application: app, elements: refs, createdAt: Date())
        latestSnapshotByPID[app.processIdentifier] = snapshotID
        pruneSnapshots()
        return observation
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        limit: Int,
        nodes: inout [LingShuComputerStateNode],
        refs: inout [Int: AXUIElement],
        visited: inout Set<CFHashCode>,
        reachedLimit: inout Bool
    ) {
        guard depth <= maxDepth else { return }
        guard nodes.count < limit else { reachedLimit = true; return }
        let identity = CFHash(element)
        guard visited.insert(identity).inserted else { return }

        let role = axString(element, kAXRoleAttribute) ?? "AXUnknown"
        let subrole = axString(element, kAXSubroleAttribute) ?? ""
        let title = sanitized(axString(element, kAXTitleAttribute))
        let help = sanitized(axString(element, kAXDescriptionAttribute) ?? axString(element, kAXHelpAttribute))
        let identifier = sanitized(axString(element, kAXIdentifierAttribute))
        let value = LingShuNativeComputerUsePolicy.redactedValue(
            role: role,
            subrole: subrole,
            title: title,
            help: help,
            identifier: identifier,
            value: sanitized(axScalarString(element, kAXValueAttribute))
        )
        let enabled = axBool(element, kAXEnabledAttribute) ?? true
        let focused = axBool(element, kAXFocusedAttribute) ?? false
        let frame = axFrame(element)
        let actions = axActions(element)
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        let draft = LingShuComputerStateNode(
            index: nodes.count + 1,
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            help: help,
            identifier: identifier,
            enabled: enabled,
            focused: focused,
            valueSettable: valueSettable,
            frame: frame,
            actions: actions
        )
        if LingShuNativeComputerUsePolicy.shouldExpose(role: role, label: draft.label, actions: actions, valueSettable: valueSettable) {
            nodes.append(draft)
            refs[draft.index] = element
        }

        guard nodes.count < limit else { reachedLimit = true; return }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, maxDepth: maxDepth, limit: limit, nodes: &nodes, refs: &refs, visited: &visited, reachedLimit: &reachedLimit)
            if nodes.count >= limit { reachedLimit = true; break }
        }
    }

    private func verifiedResult(description: String, before: CachedSnapshot) async -> String {
        try? await Task.sleep(for: .milliseconds(350))
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = (frontmost?.isTerminated == false && frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier)
            ? frontmost!
            : before.application
        let after = makeObservation(app: target, maxElements: max(before.observation.nodes.count + 20, 80), includeScreenshot: true)
        let switchedApp = target.processIdentifier != before.observation.app.pid
        let verified = switchedApp || after.diff.changed
        let verdict = verified
            ? "验证：已回读到\(switchedApp ? "前台应用切换" : "界面语义变化")。"
            : "验证：动作已发出，但回读未观察到结构变化；不要假定成功，请结合新快照检查状态。"
        return "\(description)\n\(verdict)\n\(after.modelText)"
    }

    private func activate(_ app: NSRunningApplication) {
        if !app.isActive { _ = app.activate(options: []) }
    }

    private func focusedWindowTitle(_ app: AXUIElement) -> String {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return "" }
        return sanitized(axString(windowRef as! AXUIElement, kAXTitleAttribute))
    }

    private func captureApplicationWindow(pid: pid_t) -> String? {
        guard LingShuComputerControl.isScreenCaptureTrusted(),
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates: [(id: Int, area: CGFloat)] = info.compactMap { item in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any] else { return nil }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect), rect.width > 80, rect.height > 80 else { return nil }
            return (id, rect.width * rect.height)
        }
        guard let windowID = candidates.max(by: { $0.area < $1.area })?.id else { return nil }
        let path = NSTemporaryDirectory() + "lingshu-app-\(pid)-\(UUID().uuidString.prefix(6)).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", "-l", String(windowID), path]
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func pruneSnapshots() {
        let cutoff = Date().addingTimeInterval(-snapshotLifetime)
        let expired = snapshots.filter { $0.value.createdAt < cutoff }.map(\.key)
        for key in expired { snapshots.removeValue(forKey: key) }
        if snapshots.count > snapshotLimit {
            let overflow = snapshots.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(snapshots.count - snapshotLimit)
            for item in overflow { snapshots.removeValue(forKey: item.key) }
        }
        let valid = Set(snapshots.keys)
        latestSnapshotByPID = latestSnapshotByPID.filter { valid.contains($0.value) }
    }

    private func confirmationRequired(action: String, node: LingShuComputerStateNode?) -> String {
        let target = node?.label.nonEmptyComputerUse ?? "当前目标"
        return "⚠️ 未执行：\(action)「\(target)」可能造成付款、发送、删除或其他不可逆/对外影响。请先向用户说明具体影响并取得明确确认；确认后原样重试并传 confirmed=true。"
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func axScalarString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref else { return nil }
        if let text = ref as? String { return text }
        if let number = ref as? NSNumber { return number.stringValue }
        return nil
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private func axActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func sanitized(_ value: String?) -> String {
        guard let value else { return "" }
        return String(value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(140))
    }
}

private extension String {
    var nonEmptyComputerUse: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
