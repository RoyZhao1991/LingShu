import Foundation

/// Model-neutral native Computer Use tools. The brain observes an app snapshot,
/// addresses elements by snapshot-scoped index, and receives a refreshed state
/// after every action. Legacy coordinate tools remain available as fallback.
@MainActor
extension LingShuState {
    func nativeComputerUseTools() -> [LingShuAgentTool] {
        [
            computerListAppsTool(), computerGetStateTool(), computerClickElementTool(),
            computerSetTextTool(), computerPressKeyOnElementTool(), computerScrollElementTool(),
            computerDragElementTool(), computerPerformActionTool()
        ]
    }

    private func computerListAppsTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_list_apps",
            description: "列出当前运行的 macOS 图形应用及其 bundle_id/pid。要操作指定应用时先调用它，再把应用名称、bundle_id 或 pid 传给 computer_get_state。",
            metadata: .init(effect: .readOnly, parallelPolicy: .parallelSafe)
        ) { [weak self] _ in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: false) }) { return gate }
            return await MainActor.run { LingShuNativeComputerUseRuntime.shared.listAppsText() }
        }
    }

    private func computerGetStateTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_get_state",
            description: "读取指定 macOS 应用的原生界面状态：窗口、截图路径、可见语义元素、每个元素的 #index/坐标/可用动作，并返回 snapshot_id。target 可用应用名称、bundle_id 或 pid；省略表示前台应用。后续元素动作必须使用本次 snapshot_id + index，禁止凭截图猜坐标。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"target\":{\"type\":\"string\",\"description\":\"应用名称、bundle_id、pid；省略为前台应用\"},\"max_elements\":{\"type\":\"integer\",\"description\":\"最多返回元素数，默认 80，范围 20-160\"},\"include_screenshot\":{\"type\":\"boolean\",\"description\":\"是否同时生成目标窗口截图，默认 true\"}}}",
            metadata: .init(effect: .readOnly, parallelPolicy: .serial)
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            let target = Self.jsonField(argsJSON, "target")
            let maxElements = Int(Self.jsonField(argsJSON, "max_elements") ?? "80") ?? 80
            let includeScreenshot = (Self.jsonField(argsJSON, "include_screenshot") ?? "true").lowercased() != "false"
            return await MainActor.run {
                LingShuNativeComputerUseRuntime.shared.observe(
                    target: target,
                    maxElements: maxElements,
                    includeScreenshot: includeScreenshot
                )
            }
        }
    }

    private func computerClickElementTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_click_element",
            description: "点击 computer_get_state 快照中的元素。优先执行元素原生 AXPress；不支持时才按元素中心坐标降级。动作后自动回读新快照并验证界面是否变化。付款/发送/删除等高风险目标必须先取得用户明确确认，再传 confirmed=true。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"snapshot_id\":{\"type\":\"string\"},\"index\":{\"type\":\"integer\"},\"button\":{\"type\":\"string\",\"enum\":[\"left\",\"right\"]},\"count\":{\"type\":\"integer\",\"description\":\"1 或 2\"},\"confirmed\":{\"type\":\"boolean\",\"description\":\"仅在用户已明确确认高风险动作后设 true\"}},\"required\":[\"snapshot_id\",\"index\"]}",
            metadata: Self.computerActionMetadata()
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let snapshotID = Self.jsonField(argsJSON, "snapshot_id")?.nonEmptyNativeComputerUse,
                  let index = Int(Self.jsonField(argsJSON, "index") ?? "") else {
                return "需要有效的 snapshot_id 和 index。先调用 computer_get_state。"
            }
            return await LingShuNativeComputerUseRuntime.shared.click(
                snapshotID: snapshotID,
                index: index,
                button: Self.jsonField(argsJSON, "button") ?? "left",
                count: Int(Self.jsonField(argsJSON, "count") ?? "1") ?? 1,
                confirmed: Self.boolField(argsJSON, "confirmed")
            )
        }
    }

    private func computerSetTextTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_set_text",
            description: "向快照中的输入元素写入文本。优先设置原生 AXValue，失败时聚焦元素并用键盘输入；动作后自动回读验证。结果只记录字符数，不回显敏感正文。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"snapshot_id\":{\"type\":\"string\"},\"index\":{\"type\":\"integer\"},\"text\":{\"type\":\"string\"},\"replace\":{\"type\":\"boolean\",\"description\":\"降级为键盘输入时是否先全选，默认 true\"}},\"required\":[\"snapshot_id\",\"index\",\"text\"]}",
            metadata: Self.computerActionMetadata()
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let snapshotID = Self.jsonField(argsJSON, "snapshot_id")?.nonEmptyNativeComputerUse,
                  let index = Int(Self.jsonField(argsJSON, "index") ?? ""),
                  let text = Self.jsonField(argsJSON, "text") else {
                return "需要 snapshot_id、index 和 text。"
            }
            return await LingShuNativeComputerUseRuntime.shared.setText(
                snapshotID: snapshotID,
                index: index,
                text: text,
                replace: (Self.jsonField(argsJSON, "replace") ?? "true").lowercased() != "false"
            )
        }
    }

    private func computerPressKeyOnElementTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_press_key",
            description: "在应用快照对应的上下文中按键或组合键，如 return、esc、tab、cmd+c。可带 index 先聚焦指定元素。动作后自动回读新状态。高风险提交动作仅在用户明确确认后传 confirmed=true。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"snapshot_id\":{\"type\":\"string\"},\"index\":{\"type\":\"integer\"},\"keys\":{\"type\":\"string\"},\"confirmed\":{\"type\":\"boolean\"}},\"required\":[\"snapshot_id\",\"keys\"]}",
            metadata: Self.computerActionMetadata()
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let snapshotID = Self.jsonField(argsJSON, "snapshot_id")?.nonEmptyNativeComputerUse,
                  let keys = Self.jsonField(argsJSON, "keys")?.nonEmptyNativeComputerUse else {
                return "需要 snapshot_id 和 keys。"
            }
            return await LingShuNativeComputerUseRuntime.shared.pressKey(
                snapshotID: snapshotID,
                index: Int(Self.jsonField(argsJSON, "index") ?? ""),
                keys: keys,
                confirmed: Self.boolField(argsJSON, "confirmed")
            )
        }
    }

    private func computerScrollElementTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_scroll_element",
            description: "在指定应用或元素区域滚动。dy 正=向上、负=向下；dx 正=向右、负=向左。带 index 时先把指针移到元素中心，动作后回读新状态。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"snapshot_id\":{\"type\":\"string\"},\"index\":{\"type\":\"integer\"},\"dy\":{\"type\":\"number\"},\"dx\":{\"type\":\"number\"}},\"required\":[\"snapshot_id\",\"dy\"]}",
            metadata: Self.computerActionMetadata()
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let snapshotID = Self.jsonField(argsJSON, "snapshot_id")?.nonEmptyNativeComputerUse else {
                return "需要 snapshot_id。"
            }
            return await LingShuNativeComputerUseRuntime.shared.scroll(
                snapshotID: snapshotID,
                index: Int(Self.jsonField(argsJSON, "index") ?? ""),
                dy: Self.int32Field(argsJSON, "dy"),
                dx: Self.int32Field(argsJSON, "dx")
            )
        }
    }

    private func computerDragElementTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_drag_element",
            description: "在同一应用快照里把一个元素拖到另一个元素。使用双方中心坐标，完成后自动回读验证。拖到废纸篓/删除区等高风险目标必须先由用户明确确认。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"snapshot_id\":{\"type\":\"string\"},\"from_index\":{\"type\":\"integer\"},\"to_index\":{\"type\":\"integer\"},\"confirmed\":{\"type\":\"boolean\"}},\"required\":[\"snapshot_id\",\"from_index\",\"to_index\"]}",
            metadata: Self.computerActionMetadata()
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let snapshotID = Self.jsonField(argsJSON, "snapshot_id")?.nonEmptyNativeComputerUse,
                  let from = Int(Self.jsonField(argsJSON, "from_index") ?? ""),
                  let to = Int(Self.jsonField(argsJSON, "to_index") ?? "") else {
                return "需要 snapshot_id、from_index 和 to_index。"
            }
            return await LingShuNativeComputerUseRuntime.shared.drag(
                snapshotID: snapshotID,
                fromIndex: from,
                toIndex: to,
                confirmed: Self.boolField(argsJSON, "confirmed")
            )
        }
    }

    private func computerPerformActionTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "computer_perform_action",
            description: "执行 computer_get_state 为某元素明确列出的原生辅助功能动作（如 AXPress、AXShowMenu）。action 必须来自该元素 actions 列表；执行后自动回读验证。高风险目标需先取得用户确认。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"snapshot_id\":{\"type\":\"string\"},\"index\":{\"type\":\"integer\"},\"action\":{\"type\":\"string\"},\"confirmed\":{\"type\":\"boolean\"}},\"required\":[\"snapshot_id\",\"index\",\"action\"]}",
            metadata: Self.computerActionMetadata()
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            if let gate = await MainActor.run(body: { self.computerControlGate(requiresAccessibility: true) }) { return gate }
            guard let snapshotID = Self.jsonField(argsJSON, "snapshot_id")?.nonEmptyNativeComputerUse,
                  let index = Int(Self.jsonField(argsJSON, "index") ?? ""),
                  let action = Self.jsonField(argsJSON, "action")?.nonEmptyNativeComputerUse else {
                return "需要 snapshot_id、index 和 action。"
            }
            return await LingShuNativeComputerUseRuntime.shared.performAction(
                snapshotID: snapshotID,
                index: index,
                action: action,
                confirmed: Self.boolField(argsJSON, "confirmed")
            )
        }
    }

    private nonisolated static func computerActionMetadata() -> LingShuToolMetadata {
        .init(effect: .control, parallelPolicy: .serial, resourceArgumentNames: ["snapshot_id"])
    }

    private nonisolated static func boolField(_ json: String, _ key: String) -> Bool {
        ["true", "1", "yes"].contains((jsonField(json, key) ?? "false").lowercased())
    }

    private nonisolated static func int32Field(_ json: String, _ key: String) -> Int32 {
        let value = Double(jsonField(json, key) ?? "0") ?? 0
        return Int32(max(Double(Int32.min), min(Double(Int32.max), value)))
    }
}

private extension String {
    var nonEmptyNativeComputerUse: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
