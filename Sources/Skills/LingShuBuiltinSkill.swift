import Foundation

/// **内置技能（built-in skill）**：随 app 出厂、签名可信的原生能力模块（演示与答疑、未来的浏览器/录制…）。
///
/// 硬性架构要求（用户定调 2026-06-27）:**技能分内置与外部两类,信任边界不同,代码归属不同**——
/// - **内置技能**:可信 → **可带原生 Swift 代码**,但代码归各自的技能模块(实现本协议),**绝不糊进内核**(`LingShuState`)。
/// - **外部技能**:运行时来的(discover 联网 / author 自写 / record 录制)→ **不可直接跑原生**,必须沙箱/声明式/子进程 runner
///   (未审来源零容忍,见 [[plugin-manifest-permissions]] / [[skill-self-evolution]])。
///
/// 内核只持一张「已挂载内置技能」表(`LingShuState.builtinSkills`),**一律遍历本协议统一调度**:
/// 取消/暂停/继续、用户输入分诊、工具表、`@` 菜单、声明式路由——**内核里不出现任一具体技能的专属 `if`/调用**。
/// 加/换一个内置技能 = 加一个实现本协议的模块 + 注册进表,**不碰内核**。这正是内核 ABI「核心固化 → 可信原生外围」的落地。
@MainActor
protocol LingShuBuiltinSkill: AnyObject {
    /// 挂载:内核启动时把宿主(自己)交给技能;技能经此取内核服务(预览/语音/聊天/控制面模型…)。
    func mount(host: LingShuState)

    /// 稳定 id(如 "present");声明式路由/日志用。
    var id: String { get }
    /// 展示名(如 "演示与答疑")。
    var displayName: String { get }
    /// 是否正在活动(内核据此决定是否要把用户输入拦给它、是否要暂停它)。
    var isActive: Bool { get }

    /// 本技能暴露给大脑的 agent 工具(并入工具表)。无则空。
    func tools() -> [LingShuAgentTool]
    /// 声明式 `@` 菜单项;nil = 不进菜单。
    var invocationEntry: LingShuInvocablePlugin? { get }
    /// 声明式命中(`@演示 …`)→ 执行;返回 false = 这个 id 不归本技能管(让内核试下一个)。
    /// `rest`=`@别名` 之后那段;`fullPrompt`=整条消息(含**附件块**:附件路径折进消息时在 `@别名` 之前,
    /// 只看 rest 会漏掉它,故路径类技能要从 fullPrompt 兜底抽取)。
    func routeDeclarative(id: String, rest: String, fullPrompt: String) -> Bool

    /// 本技能**活动中**拦截用户输入(如演示答疑/控制);返回 true = 已接管,内核不再走常规分诊/派发。
    func interceptActiveInput(_ prompt: String) -> Bool

    /// 内核取消/中断(关窗/停止)→ 本技能彻底停。
    func onCancel()
    /// 内核暂停(检测到用户手动操作)→ 本技能暂停(可续)。
    func onPause()
    /// 内核「继续」→ 本技能若处于可续暂停态则接着跑;返回 true = 已接管(内核不再去续别的流程)。
    func onResume() -> Bool
}

/// 默认实现:技能只实现自己用得到的钩子,其余留空(内核遍历调用时安全 no-op)。
@MainActor
extension LingShuBuiltinSkill {
    func tools() -> [LingShuAgentTool] { [] }
    var invocationEntry: LingShuInvocablePlugin? { nil }
    func routeDeclarative(id: String, rest: String, fullPrompt: String) -> Bool { false }
    func interceptActiveInput(_ prompt: String) -> Bool { false }
    func onCancel() {}
    func onPause() {}
    func onResume() -> Bool { false }
}
