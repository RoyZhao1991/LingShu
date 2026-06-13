import Foundation

struct LingShuAutonomousRunbookPlanner {
    func plan(
        objective: String,
        permissionLevel: LingShuAutonomousPermissionLevel,
        environment: LingShuAutonomousEnvironmentReport,
        memoryStatus: String
    ) -> LingShuAutonomousRunbook {
        let normalized = LingShuMemoryTextToolkit.normalize(objective)
        let profile = inferProfile(from: normalized)
        let missing = missingInformation(for: normalized, profile: profile)
        let capabilities = capabilityHints(for: profile)
        let artifacts = expectedArtifacts(for: profile)
        let reviewGates = reviewGates(for: profile, permissionLevel: permissionLevel)

        var steps = baseSteps(memoryStatus: memoryStatus)
        steps.append(contentsOf: profileSteps(for: profile))
        steps.append(.init(
            id: "review",
            title: "验收与人工接管确认",
            owner: "验收",
            detail: "按事实一致性、权限边界、产出物可用性和现场接管能力进行最后检查。",
            status: .waiting
        ))
        steps.append(.init(
            id: "retrospective",
            title: "复盘入记忆",
            owner: "记忆",
            detail: "把目标、流程、产出物、失败降级和有效经验沉淀为主线程记忆和执行记忆。",
            status: .waiting
        ))

        if !environment.canRun {
            steps.insert(.init(
                id: "repair-environment",
                title: "修复阻断项",
                owner: "自检",
                detail: "环境检测存在不可用项，必须先处理模型、工作区或产出物目录问题。",
                status: .waiting
            ), at: 1)
        }

        return .init(
            objective: objective,
            assumptions: assumptions(for: profile, environment: environment),
            missingInformation: missing,
            capabilityHints: capabilities,
            expectedArtifacts: artifacts,
            reviewGates: reviewGates,
            steps: steps
        )
    }

    private enum Profile {
        case presentation
        case capabilityBuild
        case engineering
        case general
    }

    private func inferProfile(from normalized: String) -> Profile {
        if ["汇报", "演讲", "答疑", "课题", "陈述", "ppt", "presentation"].contains(where: { normalized.contains($0) }) {
            return .presentation
        }
        if ["新增模块", "扩展能力", "能力包", "插件", "自动扩展", "生产新的功能"].contains(where: { normalized.contains($0) }) {
            return .capabilityBuild
        }
        if ["代码", "开发", "测试", "构建", "工程", "修复", "项目"].contains(where: { normalized.contains($0) }) {
            return .engineering
        }
        return .general
    }

    private func baseSteps(memoryStatus: String) -> [LingShuAutonomousRunbookStep] {
        [
            .init(
                id: "environment",
                title: "环境检测",
                owner: "环境",
                detail: "确认工作区、模型、权限、语音、记忆和能力池是否满足本次目标。",
                status: .completed
            ),
            .init(
                id: "memory",
                title: "读取记忆与上下文",
                owner: "记忆",
                detail: memoryStatus,
                status: .waiting
            ),
            .init(
                id: "objective",
                title: "目标建模与缺口确认",
                owner: "灵枢",
                detail: "将用户目标拆成约束、风险、缺失信息和可交付结果；不确定处先澄清。",
                status: .waiting
            )
        ]
    }

    private func profileSteps(for profile: Profile) -> [LingShuAutonomousRunbookStep] {
        switch profile {
        case .presentation:
            return [
                .init(id: "outline", title: "形成汇报主线", owner: "规划", detail: "根据课题定位、听众和时长动态决定讲述结构。", status: .waiting),
                .init(id: "materials", title: "生成演示与讲稿产出物", owner: "设计", detail: "按目标生成 PPT/HTML/讲稿/答疑库等候选产出，并挂入产出物清单。", status: .waiting),
                .init(id: "rehearsal", title: "自主演练与计时", owner: "监控", detail: "检查时长、语速、口径、转场和降级方案。", status: .waiting),
                .init(id: "live-qa", title: "现场汇报与答疑", owner: "执行", detail: "汇报时根据音频/视觉态势接收问题，检索项目事实后统一回答。", status: .waiting)
            ]
        case .capabilityBuild:
            return [
                .init(id: "gap", title: "能力缺口分析", owner: "规划", detail: "判断当前能力注册表是否满足目标，缺口转成能力请求。", status: .waiting),
                .init(id: "design", title: "模块设计", owner: "设计", detail: "定义输入、输出、权限、工具、验收和回滚策略。", status: .waiting),
                .init(id: "implementation", title: "实现与测试", owner: "执行", detail: "在授权边界内生成模块、测试和文档，并通过架构守卫。", status: .waiting),
                .init(id: "registration", title: "能力注册", owner: "验收", detail: "通过自测后注册为可复用能力包。", status: .waiting)
            ]
        case .engineering:
            return [
                .init(id: "scope", title: "工程范围确认", owner: "规划", detail: "确认目标目录、风险、权限和验收命令。", status: .waiting),
                .init(id: "execute", title: "工程执行", owner: "执行", detail: "调度开发、测试、审议和监控节点按任务线程推进。", status: .waiting),
                .init(id: "verify", title: "构建与测试验收", owner: "验收", detail: "执行测试、构建、产出物检查，并记录失败原因。", status: .waiting)
            ]
        case .general:
            return [
                .init(id: "capability-route", title: "能力匹配", owner: "灵枢", detail: "根据目标动态选择内部能力或外部 agent。", status: .waiting),
                .init(id: "execution", title: "执行与监控", owner: "执行", detail: "按运行时计划推进，并根据反馈调整 runbook。", status: .waiting),
                .init(id: "delivery", title: "交付结果", owner: "验收", detail: "汇总结果、风险、下一步建议和可检查证据。", status: .waiting)
            ]
        }
    }

    private func assumptions(for profile: Profile, environment: LingShuAutonomousEnvironmentReport) -> [String] {
        var values = ["流程由灵枢运行时生成，场景包只提供能力、工具和验收约束。"]
        if environment.warningCount > 0 {
            values.append("存在降级项，运行时需要准备备选路径。")
        }
        if profile == .presentation {
            values.append("短期目标是验证独立运行底座能支撑自主汇报与答疑。")
        }
        return values
    }

    private func missingInformation(for normalized: String, profile: Profile) -> [String] {
        var missing: [String] = []
        if !normalized.contains("截止") && !normalized.contains("明天") && !normalized.contains("今晚") {
            missing.append("截止时间")
        }
        if profile == .presentation {
            if !normalized.contains("分钟") { missing.append("汇报时长") }
            if !normalized.contains("老师") && !normalized.contains("学校") { missing.append("听众与现场要求") }
        }
        return missing
    }

    private func capabilityHints(for profile: Profile) -> [String] {
        switch profile {
        case .presentation:
            return ["资料读取", "汇报设计", "演示生成", "语音输出", "现场问答", "复盘"]
        case .capabilityBuild:
            return ["能力发现", "模块设计", "代码生成", "测试验收", "能力注册"]
        case .engineering:
            return ["规划", "开发", "测试", "审议", "监控", "交付"]
        case .general:
            return ["规划", "执行", "监控", "验收", "记忆沉淀"]
        }
    }

    private func expectedArtifacts(for profile: Profile) -> [String] {
        switch profile {
        case .presentation:
            return ["演示材料", "讲稿", "答疑库", "彩排记录", "现场运行记录"]
        case .capabilityBuild:
            return ["能力清单", "模块代码", "测试报告", "注册清单"]
        case .engineering:
            return ["变更记录", "测试报告", "产出物清单", "交付说明"]
        case .general:
            return ["任务记录", "结果说明", "复盘摘要"]
        }
    }

    private func reviewGates(for profile: Profile, permissionLevel: LingShuAutonomousPermissionLevel) -> [String] {
        var gates = ["事实一致性", "权限边界", "产出物可检查", "人工接管可用"]
        if permissionLevel == .full {
            gates.append("完整授权操作留痕")
        }
        if profile == .presentation {
            gates.append("时间控制")
            gates.append("现场答疑可降级")
        }
        return gates
    }
}
