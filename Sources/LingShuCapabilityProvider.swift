import Foundation

/// 完全版 #6·**能力提供方协议 + 注册表**(A2A 接缝,纯逻辑可测)。
///
/// 灵枢调度的一切外部能力(已连 MCP 工具 / 固化 skill / 命名角色 team / 自编组件 / 外部 agent)归一成"能力"。
/// **不做假精度的 qualityScore 自动路由**(那是过度工程)——只做统一**枚举**,让大脑看到全集后自己选(它已会)。
/// 加新能力源 = 实现 `LingShuCapabilityProvider`,不改调度主流程。
struct LingShuCapability: Sendable, Equatable {
    let id: String
    let description: String
    let source: String     // mcp / skill / team / authored / external
}

protocol LingShuCapabilityProvider: Sendable {
    func capabilities() -> [LingShuCapability]
}

enum LingShuCapabilityRegistry {
    /// 汇总多个提供方的能力,按 id 去重(先到先得)。纯逻辑。
    static func merge(_ providers: [any LingShuCapabilityProvider]) -> [LingShuCapability] {
        var seen = Set<String>()
        var out: [LingShuCapability] = []
        for cap in providers.flatMap({ $0.capabilities() }) {
            guard !seen.contains(cap.id) else { continue }
            seen.insert(cap.id)
            out.append(cap)
        }
        return out
    }
}
