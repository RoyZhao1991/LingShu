import Foundation

/// 超越点·灵枢当 MCP server:对外暴露的**具身能力候选工具**装配。
///
/// 注意:这些具身工具(内置浏览器自动化 / 计算机直接操作 / 语音 / 外设)是在 `mainAgentSession()` 与 spawn 子会话里
/// **由调用方追加**的,**不在 `agentBuiltinTools` 基集**里(基集只有读写改/run + 桥 + apply_patch 等)。所以对外暴露要
/// 从各能力源直接装配,再交 `LingShuEmbodimentManifest` 按暴露名集过滤。安全门仍在各 handler 内(系统授权等),
/// 不在此放松。
@MainActor
extension LingShuState {
    /// 候选具身工具集(给 MCP server `tools/list`/`tools/call` 过滤用)。
    func embodimentCandidateTools() -> [LingShuAgentTool] {
        browserTools()
            + computerControlTools()
            + [speakTool(), peripheralsTool(), labelPeripheralTool()]
    }
}
