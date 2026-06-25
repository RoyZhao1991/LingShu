import Foundation

struct LingShuTaskRuntimeCoordinator {
    func begin(
        taskID: String,
        memoryStatus: String,
        engineLabel: String,
        restored: Bool
    ) -> TaskRuntimeSnapshot {
        .init(
            taskID: taskID,
            stage: restored ? .memory : .intake,
            summary: "主线程判断本轮需要能力协作，已创建/恢复任务线程；灵枢只负责判断、分派、权限和验收。",
            currentAction: "加载执行记忆并准备权限裁决。",
            executionEngine: engineLabel,
            permissionBoundary: "待裁决",
            memoryStatus: memoryStatus,
            reviewGate: "等待执行产物",
            checks: [
                .init(title: "记忆", detail: memoryStatus, state: restored ? .done : .running),
                .init(title: "上下文", detail: "等待路由判断是否需要目标上下文", state: .waiting),
                .init(title: "权限", detail: "等待灵枢裁决执行边界", state: .waiting),
                .init(title: "工具循环", detail: "等待执行器接令", state: .waiting),
                .init(title: "Review", detail: "等待灵枢验收", state: .waiting)
            ]
        )
    }

    func afterRoute(
        _ current: TaskRuntimeSnapshot,
        route: LingShuRoutePayload,
        engineLabel: String,
        permissionBoundary: String
    ) -> TaskRuntimeSnapshot {
        var snapshot = current
        let agentNames = route.agents.map(\.agent).joined(separator: "、")
        snapshot.stage = route.needsAgents ? .permission : .review
        snapshot.summary = route.needsAgents
            ? "灵枢已完成任务路由，接下来由执行器按标准闭环推进。"
            : "灵枢判断本轮不需要进入工具循环，直接完成答复。"
        snapshot.currentAction = route.needsAgents
            ? "已分派：\(agentNames.isEmpty ? "能力运行时" : agentNames)，正在确认权限边界。"
            : "直接答复并归档本轮上下文。"
        snapshot.executionEngine = engineLabel
        snapshot.permissionBoundary = permissionBoundary
        snapshot.reviewGate = route.needsAgents ? "等待执行结果" : "已完成直接答复"
        snapshot.checks = [
            .init(title: "记忆", detail: snapshot.memoryStatus, state: .done),
            .init(title: "上下文", detail: route.summary ?? "已完成路由判断", state: .done),
            .init(title: "权限", detail: permissionBoundary, state: route.needsAgents ? .running : .done),
            .init(title: "工具循环", detail: route.needsAgents ? "等待执行器进入执行、监控、检查循环" : "无需执行", state: .waiting),
            .init(title: "Review", detail: route.needsAgents ? "等待产物回传" : "本轮由灵枢直接回复", state: route.needsAgents ? .waiting : .done)
        ]
        return snapshot
    }

    func executing(
        _ current: TaskRuntimeSnapshot,
        permissionBoundary: String
    ) -> TaskRuntimeSnapshot {
        var snapshot = current
        snapshot.stage = .executing
        snapshot.currentAction = "执行器已接收任务，进入工具循环。"
        snapshot.permissionBoundary = permissionBoundary
        snapshot.reviewGate = "等待构建、测试或执行报告"
        snapshot.checks = [
            .init(title: "记忆", detail: snapshot.memoryStatus, state: .done),
            .init(title: "上下文", detail: "已加载任务、分派和执行范围", state: .done),
            .init(title: "权限", detail: snapshot.permissionBoundary, state: .done),
            .init(title: "工具循环", detail: "正在执行：读上下文、计划、修改/产出、观察结果", state: .running),
            .init(title: "Review", detail: "等待执行器回传", state: .waiting)
        ]
        return snapshot
    }

    func monitoring(_ current: TaskRuntimeSnapshot) -> TaskRuntimeSnapshot {
        guard current.stage == .executing || current.stage == .permission else { return current }
        var snapshot = current
        snapshot.stage = .monitoring
        snapshot.currentAction = "监控执行器心跳、底层输出和产物回传。"
        snapshot.checks = [
            .init(title: "记忆", detail: snapshot.memoryStatus, state: .done),
            .init(title: "上下文", detail: "执行上下文已锁定", state: .done),
            .init(title: "权限", detail: snapshot.permissionBoundary, state: .done),
            .init(title: "工具循环", detail: "运行中；以心跳和输出判断是否存活", state: .running),
            .init(title: "Review", detail: "等待检查结果", state: .waiting)
        ]
        return snapshot
    }

    func delivered(_ current: TaskRuntimeSnapshot) -> TaskRuntimeSnapshot {
        var snapshot = current
        snapshot.stage = .delivering
        snapshot.summary = "执行器已回传结果，灵枢完成最终验收并负责对用户交付。"
        snapshot.currentAction = "等待用户 Review 或下一步指令。"
        snapshot.reviewGate = "已通过本轮验收"
        snapshot.checks = [
            .init(title: "记忆", detail: snapshot.memoryStatus, state: .done),
            .init(title: "上下文", detail: "上下文已归档", state: .done),
            .init(title: "权限", detail: snapshot.permissionBoundary, state: .done),
            .init(title: "工具循环", detail: "执行器已返回结果", state: .done),
            .init(title: "Review", detail: "灵枢已完成交付前检查", state: .done)
        ]
        return snapshot
    }

    func blocked(
        _ current: TaskRuntimeSnapshot,
        error: String
    ) -> TaskRuntimeSnapshot {
        guard current.stage != .dormant else { return current }
        var snapshot = current
        snapshot.stage = .blocked
        snapshot.summary = "能力运行时受阻，灵枢已停止继续推进，避免产生不可靠结果。"
        snapshot.currentAction = "等待用户调整任务或修复主通道。"
        snapshot.reviewGate = "未通过"
        snapshot.checks = [
            .init(title: "记忆", detail: snapshot.memoryStatus, state: .done),
            .init(title: "上下文", detail: "已保留本轮上下文", state: .done),
            .init(title: "权限", detail: snapshot.permissionBoundary, state: .done),
            .init(title: "工具循环", detail: error, state: .running),
            .init(title: "Review", detail: "阻断，未交付", state: .waiting)
        ]
        return snapshot
    }
}
