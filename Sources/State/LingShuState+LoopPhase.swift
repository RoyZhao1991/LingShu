import Foundation

/// LOOP 阶段可视化:把"理解→规划→执行→验收"的内环节实时暴露给用户(本体浮窗 + 状态栏),
/// 免得任务跑着时用户干等、不知道发生了什么。阶段由**工具调用**(withPhaseTracking 按工具名归类)+
/// **验收器**(runVerificationLoop 置 .verifying)+ **核心态切换**(enterCoreState 起止)共同驱动。
@MainActor
extension LingShuState {

    func setLoopPhase(_ phase: LingShuLoopPhase) {
        if loopPhase != phase { loopPhase = phase }
    }

    /// 给每个工具包一层"调用前先把 LOOP 阶段切到该工具对应的环节"——本体/状态栏据此实时显示理解/规划/执行中。
    /// 不改工具本身行为,只在调用前置一次相位。包在 withBatchRunner 外层:模型直接调的工具都被归类。
    func withPhaseTracking(_ tools: [LingShuAgentTool]) -> [LingShuAgentTool] {
        tools.map { tool in
            let phase = Self.loopPhase(forTool: tool.name)
            let original = tool.handler
            return LingShuAgentTool(
                name: tool.name,
                description: tool.description,
                parametersJSON: tool.parametersJSON,
                metadata: tool.metadata
            ) { [weak self] args in
                await MainActor.run { self?.setLoopPhase(phase) }
                return await original(args)
            }
        }
    }

    /// 工具名 → LOOP 环节:读取/查看/联网=理解;计划/技能=规划;其余落地动作=执行。验收由验收器单独置位。
    static func loopPhase(forTool name: String) -> LingShuLoopPhase {
        let understanding: Set<String> = [
            "read_file", "list_directory", "preview_document_text", "open_preview", "preview_scroll",
            "web_search", "screen_capture", "list_ui_elements", "computer_list_apps", "computer_get_state",
            "recall_memory", "find_images",
            "list_credentials", "get_time", "time"
        ]
        let planning: Set<String> = ["update_plan", "discover_skill", "apply_skill", "review_design"]
        if understanding.contains(name) { return .understanding }
        if planning.contains(name) { return .planning }
        return .executing   // write/edit/run/run_steps/speak/preview_next/present/计算机操作… 都是执行
    }
}
