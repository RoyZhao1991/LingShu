import Foundation

/// # 灵枢内核 ABI(应用二进制/契约接口)单一真相源
///
/// 「核心固化 → 自我编程外围 → 可插拔进化」的根基:**内核是稳定平台,外围只通过下面这几个协议接内核。**
/// 内核版本化 + 契约测试守住(协议形状变了 → `KernelABIContractTests` 编译/断言红),
/// 让外围组件(插件/感知源)无论怎么长,内核契约不被改坏。
///
/// 真相源在此(代码),人可读说明在 `Docs/灵枢内核ABI.md`(两者由契约测试钉死一致)。
///
/// 五大内核协议(任何外围都只经它们接内核):
/// 1. **核心循环** `LingShuAgentSessioning`(`LingShuAgentLoop.swift`)——大脑驱动:`send/resume/continueLoop/inject…`,
///    `.classic`/`.nested` 两实现,经 `makeAgentSession` 工厂按开关返回。
/// 2. **工具 ABI** `LingShuAgentTool`(`LingShuAgentLoop.swift`)——大脑的"四肢"接口:`{name,description,parametersJSON,handler}`。
///    外围的**动作/执行器型**组件最终都暴露成这个。
/// 3. **外围组件 runner 契约** `LingShuPluginToolProvider`(`Plugins/LingShuPluginToolProvider.swift`)——
///    一个插件 = 一个清单 + 一个 runner(子进程,语言不限):入参 JSON 走 stdin,结果取 stdout,经 P3 沙箱按声明权限跑。
///    这是"热载上线不必重编译整 app"的承载。
/// 4. **感知输入** `LingShuExternalSensorySource` + `LingShuExternalSensoryReading`(`ExternalSensory/`)——
///    外围的**传感器型**组件:`activate()`→`AsyncStream<信号>`,归一成 `LingShuExternalSensoryReading` 喂感知链,与视觉/听觉并列。
/// 5. **插件清单/权限** `LingShuPluginManifest` + `LingShuPluginPermissions`(`Plugins/LingShuPluginManifest.swift`)——
///    最小权限能力模型:声明 `provides`(给哪些工具/感知源)+ `perm_*`(读/写/网络/命令/系统)+ 风险级。安全门据此裁决上线方式。
///
/// 安全红线(最高优先,见 `Docs/灵枢内核ABI.md` §6 与 [[skill-self-evolution]]):
/// **自我编程上线的代码组件,绝不静默执行未审来源/未过门的代码**——静态门 + P3 沙箱真 confine + LLM 风险审 + 高风险首次运行强制人工审批。
enum LingShuKernelABI {

    /// 内核 ABI 语义化版本。**改动任一内核协议的形状(增删/改字段、改方法签名)必须升版本 + 更新文档 + 过契约测试。**
    /// 主版本=破坏性契约改动;次版本=向后兼容新增;修订=不影响契约的内部修缮。
    static let version = "1.0.0"

    /// 一个内核协议的稳定描述(名 + 承载文件 + 一句话职责)。契约测试与文档同引此清单,避免漂移。
    struct Contract: Equatable, Sendable {
        /// 类型/协议名(Swift 符号,改名即破坏契约)。
        let symbol: String
        /// 承载文件(相对仓库根)。
        let file: String
        /// 一句话职责。
        let role: String
        /// 该契约暴露给外围的"冻结面"关键符号(字段/方法/枚举 case 名)——契约测试逐个穿透,删改即红。
        let frozenSurface: [String]
    }

    /// 五大内核协议(顺序即文档章节序;`KernelABIContractTests` 钉死数量与符号名)。
    static let contracts: [Contract] = [
        Contract(
            symbol: "LingShuAgentSessioning",
            file: "Sources/LingShuAgentLoop.swift",
            role: "核心循环:大脑驱动一段会话(经典/嵌套两实现,工厂按开关返回)。",
            frozenSurface: ["isBlocked", "turnsUsed", "toolInvocations", "messages",
                            "setTextDeltaSink", "send", "resume", "continueLoop", "injectCorrection", "injectBriefing"]
        ),
        Contract(
            symbol: "LingShuAgentTool",
            file: "Sources/LingShuAgentLoop.swift",
            role: "工具 ABI:大脑的四肢接口(动作/执行器型外围都暴露成它)。",
            frozenSurface: ["name", "description", "parametersJSON", "handler"]
        ),
        Contract(
            symbol: "LingShuPluginToolProvider",
            file: "Sources/Plugins/LingShuPluginToolProvider.swift",
            role: "外围 runner 契约:子进程 stdin 入参 / stdout 结果,经 P3 沙箱按声明权限跑,产出真 LingShuAgentTool。",
            frozenSurface: ["ToolSpec", "makeTools", "runRunner"]
        ),
        Contract(
            symbol: "LingShuExternalSensorySource",
            file: "Sources/ExternalSensory/LingShuExternalSensorySource.swift",
            role: "感知输入:传感器型外围,activate→信号流,归一成 LingShuExternalSensoryReading 喂感知链。",
            frozenSurface: ["descriptor", "activate", "deactivate"]
        ),
        Contract(
            symbol: "LingShuPluginManifest",
            file: "Sources/Plugins/LingShuPluginManifest.swift",
            role: "插件清单/权限:最小权限能力模型(provides + perm_* + 风险级),安全门据此裁决上线方式。",
            frozenSurface: ["id", "name", "version", "providedTools", "permissions", "source", "from", "permissionSummary"]
        )
    ]

    /// 校验内核 ABI 自洽(契约非空、版本非空、无重名)。纯逻辑,供契约测试调用。
    static func selfCheck() -> Bool {
        guard !version.isEmpty, contracts.count == 5 else { return false }
        let symbols = contracts.map(\.symbol)
        return Set(symbols).count == symbols.count && contracts.allSatisfy { !$0.frozenSurface.isEmpty }
    }
}
