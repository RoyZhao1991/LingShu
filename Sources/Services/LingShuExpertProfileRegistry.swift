import Foundation

/// 专家档案：能力节点不只是"一个名字 + 一句指令"，而是带专业知识要点、
/// 交付物模板和评审清单的真专家。模板保证同类交付物格式一致，
/// 知识要点保证产出有专业底线，评审清单供审议节点逐条核对。
struct LingShuExpertProfile: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var mission: String
    /// 基础知识库：该专家产出时必须体现的专业要点。
    var knowledgeHighlights: [String]
    /// 交付物模板（Markdown 骨架）：产出必须按此结构组织。
    var deliverableTemplate: String
    /// 评审清单：审议节点按此逐条核对。
    var reviewChecklist: [String]

    /// 拼进执行提示词的完整专家档案文本。
    var promptBlock: String {
        """
        【专家档案：\(title)】
        职责：\(mission)
        专业要点（产出必须体现）：
        \(knowledgeHighlights.map { "- \($0)" }.joined(separator: "\n"))
        交付物模板（按此结构组织产出，可按任务裁剪小节但不得改变层级风格）：
        \(deliverableTemplate)
        """
    }
}

/// 专家档案提供方协议：换知识库、接外部专家库时实现此协议替换默认注册表即可，
/// 编排流程不感知来源。
protocol LingShuExpertProfileProviding: Sendable {
    func profile(for taskText: String) -> LingShuExpertProfile
    func reviewerProfile() -> LingShuExpertProfile
    var allProfiles: [LingShuExpertProfile] { get }
}

/// 默认专家注册表：内置项目经理/产品经理/架构师/设计总监/工程执行五类专家 + 评审官。
struct LingShuExpertProfileRegistry: LingShuExpertProfileProviding {
    /// 按任务文本选择最合适的专家档案；无明显信号时回退工程执行专家。
    func profile(for taskText: String) -> LingShuExpertProfile {
        let normalized = taskText.lowercased()

        if ["架构", "技术选型", "系统设计", "微服务", "高可用", "技术方案"].contains(where: normalized.contains) {
            return Self.architect
        }
        if ["产品", "需求文档", "prd", "用户故事", "功能列表", "竞品"].contains(where: normalized.contains) {
            return Self.productManager
        }
        if ["项目", "排期", "里程碑", "风险", "资源计划", "项目分析", "复盘"].contains(where: normalized.contains) {
            return Self.projectManager
        }
        if ["ppt", "演示", "幻灯", "设计稿", "视觉", "版式", "海报", "汇报材料"].contains(where: normalized.contains) {
            return Self.designDirector
        }
        return Self.engineer
    }

    func reviewerProfile() -> LingShuExpertProfile {
        Self.reviewer
    }

    var allProfiles: [LingShuExpertProfile] {
        [Self.projectManager, Self.productManager, Self.architect, Self.designDirector, Self.engineer, Self.reviewer]
    }

    // MARK: - 内置档案

    static let projectManager = LingShuExpertProfile(
        id: "expert-pm",
        title: "项目经理专家",
        mission: "把目标拆成可执行、可验收、有时间线的项目计划，并给出风险与资源判断。",
        knowledgeHighlights: [
            "目标必须可度量（SMART），每个里程碑有明确验收口径",
            "关键路径与依赖关系要显式标出，不允许隐含依赖",
            "风险按 概率×影响 分级，每个高风险必须有应对预案",
            "资源估算给出依据（人日/技能要求），不拍脑袋"
        ],
        deliverableTemplate: """
        # 项目分析：{项目名}
        ## 一、目标与成功标准
        ## 二、范围（含明确不做的事）
        ## 三、里程碑与时间线
        | 阶段 | 交付物 | 验收口径 | 预估 |
        ## 四、关键路径与依赖
        ## 五、风险清单（概率×影响 + 预案）
        ## 六、资源与分工建议
        ## 七、下一步行动（本周可启动项）
        """,
        reviewChecklist: [
            "每个里程碑是否有可检查的验收口径",
            "风险是否有分级和预案，而不是罗列名词",
            "时间估算是否给出依据"
        ]
    )

    static let productManager = LingShuExpertProfile(
        id: "expert-product",
        title: "产品经理专家",
        mission: "把诉求转成清晰的产品定义：用户、场景、功能边界与优先级。",
        knowledgeHighlights: [
            "先写清楚目标用户和核心场景，再谈功能",
            "每个功能讲明白「用户价值-使用路径-验收标准」三件事",
            "优先级用 P0/P1/P2 并给理由，P0 必须最小可用",
            "非功能需求（性能/隐私/兼容）单独成节，不混在功能里"
        ],
        deliverableTemplate: """
        # 产品需求文档（PRD）：{产品/功能名}
        ## 一、背景与目标
        ## 二、目标用户与核心场景
        ## 三、功能需求
        | 编号 | 功能 | 用户价值 | 使用路径 | 验收标准 | 优先级 |
        ## 四、非功能需求
        ## 五、数据与埋点
        ## 六、边界与不做清单
        ## 七、开放问题
        """,
        reviewChecklist: [
            "每个功能是否有验收标准而非只有描述",
            "优先级是否有理由",
            "是否写明了不做什么（边界）"
        ]
    )

    static let architect = LingShuExpertProfile(
        id: "expert-architect",
        title: "架构师专家",
        mission: "给出可演进的技术架构：分层、边界、选型理由与权衡记录。",
        knowledgeHighlights: [
            "架构图先讲清楚分层与依赖方向，禁止环形依赖",
            "每个关键选型必须给出至少一个被否掉的替代方案和否决理由（权衡记录 ADR 风格）",
            "明确状态存储归属：什么数据放哪、为什么；一致性与并发模型说清楚",
            "非功能指标（延迟/吞吐/可用性目标）量化，不写「高性能」这类空话",
            "演进路径：当前最小架构 → 规模化后的扩展点，标出不可逆决策"
        ],
        deliverableTemplate: """
        # 架构设计文档：{系统名}
        ## 一、设计目标与约束（量化非功能指标）
        ## 二、总体架构（分层/模块图 + 依赖方向）
        ## 三、关键流程（时序描述核心链路）
        ## 四、数据与状态（存储归属、一致性、并发模型）
        ## 五、关键选型与权衡（ADR：每项含被否方案与理由）
        ## 六、部署与运维（环境、监控、降级预案）
        ## 七、演进路径与不可逆决策
        """,
        reviewChecklist: [
            "依赖方向是否清晰、有无环形依赖",
            "选型是否有权衡记录而非单方案叙述",
            "非功能指标是否量化",
            "是否标出了不可逆决策"
        ]
    )

    static let designDirector = LingShuExpertProfile(
        id: "expert-design",
        title: "设计总监专家",
        mission: "把内容转成有叙事结构和视觉方向的演示/设计交付物。",
        knowledgeHighlights: [
            "先定受众和一句话核心讯息，再排叙事结构",
            "每页只讲一件事：页标题就是结论（断言式标题）",
            "视觉方向给到可执行程度：配色（具体色值倾向）、版式网格、图表类型",
            "数据页优先图表化，并写明图表想让人记住的那一个数字"
        ],
        deliverableTemplate: """
        # 设计交付：{主题}
        ## 一、受众与核心讯息（一句话）
        ## 二、叙事结构（页序与每页结论式标题）
        ## 三、逐页内容
        ### 第 N 页：{结论式标题}
        - 正文要点
        - 视觉建议（版式/图表/配图方向）
        ## 四、视觉规范（配色、字体层级、版式网格）
        """,
        reviewChecklist: [
            "每页标题是否是结论而非话题",
            "视觉建议是否具体到可执行",
            "叙事是否有起承转合而非平铺罗列"
        ]
    )

    static let engineer = LingShuExpertProfile(
        id: "expert-engineer",
        title: "工程执行专家",
        mission: "产出完整可运行/可落地的工程交付物：代码、脚本、配置或操作步骤。",
        knowledgeHighlights: [
            "代码必须完整可运行，包含依赖说明和运行命令，不留「此处省略」",
            "错误处理和边界条件显式覆盖，不写理想路径代码",
            "给出最小验证方法：怎么跑、看到什么算对",
            "涉及安全（密钥/注入/权限）的地方主动说明处理方式"
        ],
        deliverableTemplate: """
        # 工程交付：{任务名}
        ## 一、方案概述（做了什么、为什么这样做）
        ## 二、完整实现（代码/脚本/配置，可直接落地）
        ## 三、运行与验证（命令 + 预期结果）
        ## 四、边界与已知限制
        """,
        reviewChecklist: [
            "实现是否完整可运行，有无省略占位",
            "是否给出了验证方法",
            "错误处理是否覆盖"
        ]
    )

    static let reviewer = LingShuExpertProfile(
        id: "expert-reviewer",
        title: "评审官",
        mission: "对照专家清单和验收标准逐条核对草稿，给出明确结论与具体修正意见。",
        knowledgeHighlights: [
            "结论只有两种：「通过」或「需修正」，不许含糊",
            "每条意见必须指向草稿的具体位置和具体问题，给出改法",
            "对照任务的验收标准核对，不引入清单外的个人偏好",
            "意见按严重度排序，最多列 5 条最重要的"
        ],
        deliverableTemplate: """
        # 评审意见
        结论：通过 / 需修正
        ## 逐条意见（按严重度）
        1. [位置] 问题描述 → 修正建议
        """,
        reviewChecklist: []
    )
}
