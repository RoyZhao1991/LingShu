import Foundation

/// **灵枢自检(自我认知)**:让灵枢运行时掌握自己的**整体架构 + 实时能力**——
/// 供大脑答自指问题、规划工作、自我进化时拉准确的自我认知(不靠静态 seed 瞎猜),也供用户在面板里查看。
///
/// 分两部分:`architecture`=策展的分层架构(相对稳定,描述「灵枢是怎么搭的」);
/// `capabilities`=运行时实时拼装(当前大脑/工具/agent插件/技能/感知/记忆/自主状态,描述「此刻具体有什么」)。
/// 纯值类型,渲染逻辑可单测;实时能力的拼装在 `LingShuState+SelfInspection`。
struct LingShuSelfInspection: Equatable {
    struct Section: Equatable {
        let title: String
        let items: [String]
    }

    /// 一句话自述(大脑可直接用作自我介绍开场)。
    let oneLiner: String
    /// 整体架构(分层)。
    let architecture: [Section]
    /// 当前能力(实时快照)。
    let capabilities: [Section]

    /// 完整自检报告(markdown,供面板展示 / `self_inspect` 工具返回给大脑)。
    func markdown() -> String {
        var out = "# 灵枢自检\n\n\(oneLiner)\n\n## 整体架构\n\n"
        for s in architecture {
            out += "**\(s.title)**\n"
            out += s.items.map { "- \($0)" }.joined(separator: "\n")
            out += "\n\n"
        }
        out += "## 当前能力(实时)\n\n"
        for s in capabilities {
            out += "**\(s.title)**\n"
            out += s.items.map { "- \($0)" }.joined(separator: "\n")
            out += "\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 精简版(单段,供注入大脑上下文/语音自述,不刷屏)。
    func brief() -> String {
        let arch = architecture.map(\.title).joined(separator: "、")
        let caps = capabilities.flatMap(\.items).prefix(6).joined(separator: ";")
        return "\(oneLiner) 架构分层:\(arch)。当前:\(caps)。"
    }

    /// **策展的分层架构**(相对稳定,改架构时同步这里——这是灵枢对自身设计的权威自述)。
    static func architectureOverview() -> [Section] {
        [
            .init(title: "中枢 · agent 循环骨干", items: [
                "统一 agent 循环(模型即编排者):理解→规划→工具循环→验收;主会话/自主/派发共用一套",
                "单串行输入:任一回合或子线程在跑时,新输入进串行队列、逐条处理(不再双线并行,避免上下文污染)",
                "任务派发=独立隔离会话:每条任务有自己的上下文、记录、窗口,互不串台;子→主只同步蒸馏简报",
            ]),
            .init(title: "模型网关(可换脑)", items: [
                "HTTP 多格式(Responses / Chat-Completions / Anthropic)+ 前缀缓存 + 真流式",
                "大脑可热切换、换脑后记忆延续;codex/claude 不是大脑,是注册式 agent 插件",
            ]),
            .init(title: "实时感知", items: [
                "视觉(屏幕/摄像头)、听觉(麦克风/系统声音)、外接感知——三层分离、可插拔汇聚成标准输入",
                "本地解析优先;启用云端能力时仅发送必要内容,留存与处理边界以对应服务商条款为准",
            ]),
            .init(title: "记忆 v2(知识图谱)", items: [
                "Obsidian 化原子笔记 + 别名归一 + 双链 + 园丁自维护",
                "additive 召回(只进后缀不碰前缀缓存,保命中率)",
            ]),
            .init(title: "插件 · agent 接入", items: [
                "声明式 @编排(@Codex 开发 @Claude 验收):确定性直达,跳过大脑误判 + 跨厂商验收",
                "agent 即插件:被告知本机有某 CLI agent→注册→@调用/编排,零硬编码",
                "示范即技能:看你做一遍→抽 SKILL.md→以后一句话带新参数 replay",
            ]),
            .init(title: "自主 · 在岗 · 定时", items: [
                "独立运行(按材料做汇报/入会/答疑/纪要)+ 在岗常驻;定时调度(真持久,不伪造 launchd/crontab)",
                "断网=基础设施故障≠任务失败→暂停→联网自动续跑",
            ]),
            .init(title: "计算机 · 外设控制", items: [
                "看屏幕 + 点按/填表/滚动(经你许可);统一外设中枢:检测通用、控制分适配器",
            ]),
            .init(title: "执行纪律", items: [
                "maker≠checker 跨厂商验收门 + 完成闸防伪完成;真产出 + 实测证据,假 demo 零容忍",
                "可插拔自进化:内核 ABI 固化,外围工具/技能/模块可自编、可启停、可回退",
            ]),
        ]
    }
}
