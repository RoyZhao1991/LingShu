import Foundation

/// Task records persist stable internal actor/role identifiers. This presenter translates
/// only system-owned identifiers at display time, so localization never changes filtering,
/// lineage, or stored task history.
enum LingShuTaskParticipantLocalization {
    private static let englishActors: [String: String] = [
        "灵枢": "Nous",
        "你": "You",
        "用户": "User",
        "主人": "Owner",
        "目标认知": "Goal Cognition",
        "能力探测": "Capability Discovery",
        "工具": "Tools",
        "主脑": "Brain",
        "主线程": "Main Thread",
        "主线程分诊": "Thread Routing",
        "主线程记忆": "Main-thread Memory",
        "任务气泡": "Task Bubble",
        "任务账本": "Task Ledger",
        "任务队列": "Task Queue",
        "问答队列": "Conversation Queue",
        "输入队列": "Input Queue",
        "派发队列": "Dispatch Queue",
        "派发引擎": "Dispatch Engine",
        "角色规划": "Role Planning",
        "动态工作流": "Dynamic Workflow",
        "工作流": "Workflow",
        "编排": "Orchestration",
        "分阶段": "Stages",
        "续跑": "Resume",
        "执行恢复": "Execution Recovery",
        "后台守候": "Background Watch",
        "长命令": "Long Command",
        "运行时": "Runtime",
        "工作目录": "Working Directory",
        "配置": "Configuration",
        "权限中枢": "Permission Center",
        "沙箱": "Sandbox",
        "护栏": "Guardrails",
        "内核校验闸门": "Kernel Validation Gate",
        "完成闸": "Completion Gate",
        "独立运行": "Autonomous Run",
        "独立验收": "Independent Review",
        "真实效果验收": "Outcome Validation",
        "验收": "Acceptance",
        "审查员": "Reviewer",
        "checker会话": "Checker Session",
        "确定性查证": "Deterministic Verification",
        "设计审计": "Design Review",
        "能力图谱": "Capability Graph",
        "能力评估": "Capability Assessment",
        "能力获取": "Capability Acquisition",
        "能力运行时": "Capability Runtime",
        "能力需求": "Capability Requirements",
        "自编外围": "Self-built Capability",
        "自我进化": "Self Improvement",
        "经验复用": "Experience Reuse",
        "经验沉淀": "Experience Capture",
        "记忆": "Memory",
        "上下文压缩": "Context Compression",
        "上下文归属": "Context Resolution",
        "模型通道": "Model Channel",
        "弱脑": "Fallback Brain",
        "脑力分": "Brain Score",
        "脑力测试": "Brain Test",
        "感知": "Perception",
        "视觉": "Vision",
        "语音": "Voice",
        "声线闸门": "Voice Gate",
        "身份锁": "Identity Lock",
        "设备发现": "Device Discovery",
        "外设": "Peripherals",
        "计算机操作": "Computer Use",
        "预览控制": "Preview Control",
        "交互交付": "Interactive Delivery",
        "人机协作探针": "Human Collaboration Probe",
        "会议": "Meeting",
        "演示与答疑": "Presentation & Q&A",
        "演示运行器": "Presentation Runner",
        "反馈": "Feedback",
        "干预": "Intervention",
        "撤销": "Undo",
        "固化": "Persistence",
        "在岗": "On Duty",
        "现场": "Live Session",
        "声明式调用": "Declarative Call",
        "模块变体": "Module Variant",
        "定时触发": "Scheduled Trigger",
        "定时调度": "Scheduler",
        "用量": "Usage",
        "系统": "System",
        "第④站": "Stage 4",
        "第⑤站": "Stage 5",
        "agent插件": "Agent Plugin",
        "agent状态理解": "Agent Status Understanding",
        "Agent循环": "Agent Loop"
    ]

    private static let englishRoleTitles: [String: String] = [
        "expert-pm": "Project Manager",
        "expert-product": "Product Manager",
        "expert-architect": "Solution Architect",
        "expert-design": "Design Director",
        "expert-engineer": "Engineering Executor",
        "expert-reviewer": "Reviewer"
    ]

    static func actor(_ value: String, language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let translated = englishActors[trimmed] { return translated }

        if trimmed.hasPrefix("agent·") {
            return "Agent · " + String(trimmed.dropFirst("agent·".count))
        }
        if trimmed.hasPrefix("独立验收·") {
            return "Independent Review · " + String(trimmed.dropFirst("独立验收·".count))
        }
        return value
    }

    static func roleTitle(
        _ value: String,
        roleID: String?,
        language: LingShuVoiceLanguage
    ) -> String {
        guard language == .english else { return value }
        if let roleID, let translated = englishRoleTitles[roleID] { return translated }

        let exact: [String: String] = [
            "项目经理专家": "Project Manager",
            "产品经理专家": "Product Manager",
            "架构师专家": "Solution Architect",
            "设计总监专家": "Design Director",
            "工程执行专家": "Engineering Executor",
            "评审官": "Reviewer"
        ]
        return exact[value] ?? actor(value, language: language)
    }

    static func semanticRole(_ value: String, language: LingShuVoiceLanguage) -> String {
        switch value.lowercased() {
        case "checker": return language == .english ? "Checker" : "评审"
        case "maker": return language == .english ? "Maker" : "执行"
        default: return value
        }
    }
}
