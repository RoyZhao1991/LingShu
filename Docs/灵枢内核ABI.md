# 灵枢内核 ABI（契约接口)

> **内核 ABI 版本:1.0.0**
>
> 目的:把灵枢的核心能力固化成**稳定平台**。外围组件(插件 / 感知源 / 执行器)无论怎么自我生长,
> **只能通过下面五个协议接内核**;内核版本化、由契约测试守住,绝不被外围改坏。
>
> 真相源 = 代码 `Sources/Kernel/LingShuKernelABI.swift`(版本 + 协议清单)+ 各协议定义文件。
> 守门 = `Tests/LingShuMacTests/KernelABIContractTests.swift`(协议形状变 → 编译/断言红)。
>
> 维护规则:**改动任一内核协议的形状(增删/改字段、改方法签名、改名)= 破坏性契约改动**,必须:
> ① 升 `LingShuKernelABI.version`(主版本)② 更新本文档 ③ 过/改契约测试。向后兼容的新增升次版本。

---

## 0. 设计取向:核心固化 → 自我编程外围 → 可插拔进化

灵枢 = **大脑(大模型推理)+ 四肢(工具)+ 感知(输入)**,壳工程只负责"把大脑接上四肢 + 把感知喂进来 + 把动作落出去"。

终极目标(贾维斯式):接上一个新传感器/执行器 → 灵枢**自己写驱动组件、沙箱测通、过安全门、热载上线、然后真的用它感知世界/控制硬件**。
要做到这点,内核必须是**不变的稳定平台**:

```
        ┌─────────────────────── 内核(稳定,版本化)───────────────────────┐
新需求 → │  ① 核心循环  ② 工具 ABI  ③ runner 契约  ④ 感知输入  ⑤ 清单/权限  │ → 真用它感知/动作
        └──────────────────────────────────────────────────────────────────┘
                ▲ 外围只通过这五个协议接内核(下面逐个固化)
   外围组件 = 一个插件:一个【清单(provides + perm_*)】+ 一个【runner(子进程,语言不限)】
   → 热载上线**不必重编译整 app**(写到插件目录,插件系统加载即生效)
```

---

## 1. 五大内核协议(外围唯一入口)

### ① 核心循环 `LingShuAgentSessioning`
- **文件**:`Sources/LingShuAgentLoop.swift`
- **职责**:大脑驱动一段会话的能力抽象。`actor` 约束。
- **冻结面**:`isBlocked` / `turnsUsed` / `toolInvocations` / `messages`(只读态);
  `setTextDeltaSink(_:)` / `send(_:)` / `resume(_:)` / `continueLoop()` / `injectCorrection(_:)` / `injectBriefing(_:)`。
- **两份实现**:`LingShuAgentSession`(`.classic` 经典连续循环)、`LingShuNestedAgentSession`(`.nested` 嵌套分阶段)。
- **唯一构造点**:`makeAgentSession(...)` 工厂(`Sources/State/LingShuState+AgentSessionFactory.swift`)按 `agentLoopVariant` 开关返回实现。
  **所有任务型会话(主/自主/派发/spawn)都经它创建。** 加新循环只要也 conform 本协议即可被工厂返回、热切换。
- **配套契约类型**:`LingShuAgentMessage`(role/content/toolCalls/toolCallID)、`LingShuAgentToolCall`(id/name/argumentsJSON)、
  `LingShuAgentModel`(`respond` / `respondStreaming`,注入接口)、`LingShuAgentRunResult`(`.completed` / `.blocked` / `.maxTurnsReached` / `.interrupted` 四态)。

### ② 工具 ABI `LingShuAgentTool`
- **文件**:`Sources/LingShuAgentLoop.swift`
- **职责**:大脑的"四肢"接口。外围的**动作型/执行器型**组件最终都暴露成它。
- **冻结面**:`name` / `description` / `parametersJSON`(OpenAI 风格 JSON schema,默认空对象) / `handler: @Sendable (String) async -> String`(收 arguments JSON,返回结果文本)。
- **约定**:handler **绝不抛**(工具层要稳,错误也以文本返回);新能力 = 加一条这样的工具,**不写硬编码控制器**。

### ③ 外围 runner 契约 `LingShuPluginToolProvider`
- **文件**:`Sources/Plugins/LingShuPluginToolProvider.swift`
- **职责**:让一个插件**贡献真正的 `LingShuAgentTool`**——这是"热载上线不重编译整 app"的承载。
- **冻结面**:`ToolSpec`(name/description/parametersJSON)、`makeTools(manifest:specs:runnerExecutable:runnerArguments:sandbox:timeout:)`、
  `runRunner(...)`。
- **子进程契约(语言不限:Python/Node/Shell/二进制)**:
  - 调用形式 `<解释器> <runner脚本> <toolName>`;
  - **入参 JSON 走 stdin**,**结果取 stdout**(纯文本/JSON);非零退出取 stderr 摘要;
  - 软超时杀进程(默认 30s),不让外围吊死回合;
  - `sandbox=true` 时经 **P3 `LingShuPluginSandbox`**(`sandbox-exec` SBPL)按 manifest 权限 confine。
- **live 接线**:`LingShuState+AgentSkills.userSkillProvidedTools()` 把"声明了 `provides:` + 带 runner 脚本"的启用插件接成 live 工具,
  并入 `agentBuiltinTools` → 主会话/派发/自主**所有会话**可调。

### ④ 感知输入 `LingShuExternalSensorySource` + `LingShuExternalSensoryReading`
- **文件**:`Sources/ExternalSensory/LingShuExternalSensorySource.swift`、`…/LingShuExternalSensoryModels.swift`
- **职责**:外围的**传感器型**组件。每类设备实现一个 source,跑自己的线程/隔离域。
- **`LingShuExternalSensorySource` 冻结面**:`descriptor`(静态描述)、`activate() -> AsyncStream<LingShuExternalSensorySignal>`(幂等,状态+读数都从这出)、`deactivate()`。
- **`LingShuExternalSensorySignal` 冻结面**:`.status` / `.reading` / `.notification` / `.fatal` 四 case。
- **`LingShuExternalSensoryReading`(归一标准输入)冻结面**:`channel` / `sourceID` / `timestamp` / `headline` / `detail` / `category` / `originApp` / `salience`(0…3) / `metadata`。
- **汇聚**:`LingShuExternalSensoryHub` 把各源读数汇聚成 `situationContribution()`,与视觉/听觉并列喂大脑;`ingestForTesting` 供注入。
- **运行时动态注册(M2 已落)**:`registerSource(_:autoEnable:)` / `unregisterSource(_:)` / `isRegistered(_:)`——自编传感器型外围上线即热注册进 Hub,**内核不变、源可插拔生长**。
- **runner 驱动的传感器源(M2)**:`LingShuRunnerSensorySource`——周期性跑外围 runner(经契约③ + P3 沙箱),把 stdout 的读数 JSON 解析成 `LingShuExternalSensoryReading` 投进感知流(`parseReadings` 纯逻辑可单测)。这是传感器型外围的执行体,与动作型共用同一条 runner 契约。

### ⑤ 插件清单/权限 `LingShuPluginManifest` + `LingShuPluginPermissions`
- **文件**:`Sources/Plugins/LingShuPluginManifest.swift`
- **职责**:最小权限能力模型——外围必须**声明它要碰什么**,系统据此审批 + 越权检测 + 沙箱 confine。
- **`LingShuPluginManifest` 冻结面**:`id` / `name` / `version` / `providedTools` / `permissions` / `source`;
  `from(frontmatter:source:)`(从 skill frontmatter 解析)、`permissionSummary`(人可读)。
- **`LingShuPluginPermissions`**:`fileRead` / `fileWrite`(路径/glob,`**`跨/、`*`不跨/) / `network`(域名,`*`=任意) / `shell` / `systemSensitive`。
- **frontmatter 约定键**:`perm_read` / `perm_write` / `perm_network`(逗号分隔) / `perm_shell` / `perm_system`(true/false) / `provides` / `version`。缺省 = **最小权限**。
- **风险评级**(`LingShuPluginPermissionChecker.riskLevel`):系统敏感=高;跑命令且(任意联网或任意写)=高;三者任一=中;否则低。
- **越权检测/作用域匹配**:`LingShuPluginPermissionChecker`(glob + 域名,纯逻辑)。

---

## 2. 外围组件 = 一个插件(自我编程的对象)

一个外围组件就是用户 Skills 目录(`~/Library/Application Support/LingShu/Skills/*.md`)下的**一个 `.md`**:

```markdown
---
id: <命名空间隔离的唯一 id>
title: <人可读名>
version: 1.0
provides: <工具名>            # ② 它暴露的工具(动作型),逗号分隔
perm_network: api.xxx.com     # ⑤ 最小权限声明(只声明真要碰的)
perm_read: ~/xxx
script_name: runner.py        # ③ runner 脚本文件名(扩展名决定解释器:.py/.sh/.js)
---

## 专业要点 / 交付物模板 / 评审清单   # 提示部分(可选)

## 生成脚本                    # ③ runner:子进程,stdin 收 JSON 入参 / stdout 回结果
```python
import sys, json
args = json.loads(sys.stdin.read() or "{}")
print(...)                     # 结果写 stdout
```
```

- **传感器型**外围:产出 `LingShuExternalSensoryReading` 喂感知链(④);
- **执行器/动作型**外围:暴露成 `LingShuAgentTool`(②,经 runner 契约 ③)。
- 落盘 + `reloadUserSkills()` 热载即生效,**不重编译整 app**。

---

## 3. 自我编程外围的安全红线(最高优先,绝不可破)

见 [[skill-self-evolution]] / [[no-fake-demos]]。**自我编程上线的代码组件,绝不静默执行未审来源/未过门的代码**:

1. **静态门** `LingShuSkillSafetyGate.scan`:挡销毁/提权/远程执行/读凭据/外传(高置信度拦截)。命中即**拒绝上线**。
2. **P3 沙箱** `LingShuPluginSandbox`:`sandbox-exec` 默认拒绝,只放声明的写路径/网络;runner 一律在沙箱里跑。
3. **LLM 风险审** `reviewScriptRisk`:对来源不明脚本输出 `RISK=none/low/high` + 风险点;**保守 fail-safe**(只有明确无风险才放行自动上线)。
4. **高风险首次运行强制人工审批**:有风险/声明权限偏高 → 装但**隔离**(`setQuarantine`),首次运行其脚本弹审批,即便会话已"完全授权"。

`author_component`(M1 四肢)就是把"需求 → 写 runner+清单 → **沙箱试跑** → 静态门 → LLM 风险审 → 安全则上线/有风险则隔离"这条闭环固化成一条工具,**任何一关不过都不静默上线**。

---

## 4. 分期(围绕"核心固化 → 自我编程外围 → 可插拔进化")

| 期 | 目标 | 状态 |
|---|---|---|
| **M0 固核** | 五协议显式化 + ABI 文档 + 契约测试,内核稳成平台 | ✅ 本文档 + `KernelABIContractTests` |
| **M1 自编工具型外围** | `author_component`:大脑自写一个纯软件外围(查 API/解析)→ 沙箱测 → 安全门 → 热载 → 真调通 | ✅ 端到端最小闭环 |
| **M2 自编传感器型外围** | 大脑写一个 source 插件(本机信号打底),数据真进感知链、`perceive` 拉得到 | ✅ Hub 动态注册 + `LingShuRunnerSensorySource` + `author_component(component_kind=sensor)` |
| **M3 硬件接入闭环** | 接真外设→ 发现→自写驱动→上线→真感知 | ✅ 机制全通:`discover_devices` 枚举真硬件+驱动缺口 → 自写**真专用硬件驱动**(电池管理控制器 IOKit 遥测:温度/电芯电压/循环数)→ 沙箱读真硬件 → 隔离/审核 → 上线 → Hub → perceive 拿到真硬件态;缺口闭合。⚠️ 外接 USB-serial(ESP32 类)真设备数据=同机制、待真外设人工验(本机无外设) |
| **M4 执行器/动作** | 自编动作型外围控制真实设备(舵机/继电器/智能插座)→ "控制机甲"物理落点 | ✅ 架构全通:第三类 `kind=actuator` + 执行安全模型 `LingShuActuatorSafety`(reversible/physical)+ `actuatorGatedTool`(physical 每次执行确认门)。实测可逆音量执行器真改硬件输出✓、physical 舵机执行器每次确认拦截✓。⚠️ 真舵机/继电器接线=同机制、待真外设人工验 |

---

## 变更日志

- **2026-06-20 v1.0.0**:首版。五大内核协议固化(核心循环/工具 ABI/runner 契约/感知输入/清单权限)+ 契约测试守门 + `LingShuKernelABI` 单一真相源。M1 `author_component` 自编工具型外围闭环落地。
- **2026-06-20 (v1.0.0,无协议形状变更)**:M2 自编传感器型外围落地——感知输入协议④补**运行时动态注册**(`registerSource`/`unregisterSource`)+ `LingShuRunnerSensorySource`(runner 驱动源,复用契约③)+ `author_component(component_kind=sensor)`。数据真进感知链、`perceive` 拉得到、跨重启持久化。五大协议**形状未变**故 ABI 版本不动(纯 additive 实现 + Hub 方法)。
- **2026-06-20 (v1.0.0,无协议形状变更)**:M4 执行器/动作型外围架构——`author_component` 第三类 `component_kind=actuator`(控制真实设备,暴露工具 + `actuator_target`/`actuator_risk`);执行安全模型 `LingShuActuatorSafety`(reversible 首次审批 / **physical 每次执行强制确认**,非交互安全拒绝);`actuatorGatedTool` 在工具装配处给 physical 执行器包每次确认门(复用 run_command `forceConfirm` 审批);`LoadedSkill.frontmatter` 补字段供识别 actuator_risk/sensor_channel。实测:可逆音量执行器真改硬件输出、physical 舵机执行器每次确认拦截。执行器 runner 在现有 P3 沙箱即可 effect(osascript/Apple Events 通)。
- **2026-06-20 (v1.0.0,无协议形状变更)**:M3 硬件接入闭环——`discover_devices`(内核四肢,`LingShuDeviceDiscovery` 纯解析)枚举真硬件(串口/USB/蓝牙/电源控制器)+ 驱动缺口分析;自写**真专用硬件驱动**(电池管理控制器 IOKit `AppleSmartBattery` 遥测:温度/电芯电压/循环数/瞬时电流——非一行命令可得)→ 沙箱读真硬件 → 隔离审核 → 上线 → Hub → perceive 真感知 → 缺口闭合。沙箱无需放宽(ioreg 经 mach-lookup 可读 IORegistry)。外接 ESP32 串口同机制、待真外设人工验。
