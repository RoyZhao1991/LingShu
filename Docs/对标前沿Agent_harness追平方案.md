# 灵枢:对标 Codex / Claude Code 的 harness 追平与超越 —— 落地方案

> 交给新执行线程的自包含方案。读完即可动手。
> **铁律:全程通用、零定制(绝不接受定制化/per-case 硬编码);安全红线不动只增不减;每期单测全绿 + .app E2E;真假分级、零假 demo。**

---

## 0. 背景(冷启动必读)

灵枢 = 大脑(可换的大模型)+ 四肢(工具)+ 感知 + 壳(本仓库)。核心是统一 agent 循环(`Sources/LingShuAgentLoop.swift`,内核 ABI 见 `Docs/灵枢内核ABI.md`)。

**本方案要解决的问题:** 在**同一个大模型**前提下(即不比模型聪明,只比 agent 框架),灵枢的 harness 与 Codex / Claude Code 还有差距。已用内置脑力基准(`LingShuBrainBenchmark`,49 题含真编码/生产任务隐藏用例判分)实测坐实:**当前脑(DeepSeek)在可客观判分的有界任务上 ≈ 前沿(各难度档水位 易100/中100/难93/极难100)**。所以差距**不在"会不会解题",在 harness 的工程层**:鲁棒性、薄基线、编辑精度、上下文压缩成熟度、生态、编排深度、延迟。

**本会话已补上的(基线,别重做):**
- ✅ 会话内语义压缩:`LingShuAgentSession.compactHistoryIfNeeded`(超窗口早段蒸馏成滚动「前情提要」,失败回退硬裁剪)。
- ✅ 一等公民快搜索:`search_text`(`Sources/State/LingShuState+SearchTool.swift`,ripgrep→grep 兜底)。
- ✅ 脑力分旋钮雏形:`harnessKnobPrefix`(`Sources/State/LingShuState+BrainScore.swift`,强脑放权;仅软化提示,未真薄基线)。
- ✅ 能力评测:`LingShuBrainBenchmark`(难度加权 + 部分给分 + 难度档水位 + 跨脑对比)。

**结论(指导本方案):** 核心剩余差距是**实战鲁棒性**(根因=被多少真实流量锤过),其余都是已知可逐项补的工程项。**超越点**:灵枢可做"**自适应 harness**"(随测得能力薄/厚切换)、**知识图谱增强的无损压缩**、**确定性验收门**、**自评测+自 soak 回归门**——这些是 CC/Codex 没有的,且全部通用。

---

## 1. 总原则

| 取向 | 含义 |
|---|---|
| **通用** | 任何方案必须对**任意任务/任意模型**成立;领域特定的东西只能进**数据(知识笔记/自编组件/题库)**,绝不进壳代码分支。 |
| **薄即是多** | harness 默认让开、信任模型;脚手架只在**确定性校验失败**时按需介入(已有升级阶梯 `LingShuCapabilityEscalation`)。 |
| **确定性优先** | 能用确定性门校验的(测试跑绿/运行不崩/隐藏用例/不变量断言)就别用 LLM 自评——这是灵枢的现有优势,保留并扩大。 |
| **安全硬闸** | 不可逆/对外动作先确认、未审代码不静默执行——**不随任何旋钮放松**。 |

---

## 2. 逐项差距 → 通用解决方案

> 每项:现状(代码实锚)/ 通用方案 / 改哪些文件 / 验收 / 超越点。

### 差距 1(最大)·harness 实战鲁棒性

**现状:** 已有 `LiveSoakTests`/`ExecutionResilienceTests`/`ConcurrencyManagerTests`/`NetworkResumeTests`,但覆盖的是"想得到的场景";历史上多次出现根因 bug(如验收门 `batchInterruptRequested` 粘滞泄漏旁路、语音死锁)。

**通用方案(三层,全通用):**
1. **不变量化(消灭 bug 类,而非补实例)**:给 agent 循环定义一组**全局不变量**,在每个回合边界 assert:① 任一打断标志(`batchInterruptRequested` 等)在回合结束必复位;② 上下文里无孤儿 tool 结果;③ 循环总能到终态(完成/卡住/停滞),不 wedge;④ 历史不超 token 预算。把这些做成**运行期断言 + 单测守卫**,让整类 bug 设计上不可能。
2. **属性/混沌测试层(通用)**:新增 `AgentLoopFuzzTests` —— 随机生成{任务序列、工具成功/失败/超时、网络中断、中途打断、超长会话},跑 agent 循环,断言上面的不变量恒成立(用 `LingShuScriptedAgentModel` 注入确定性随机,脱网可 CI)。这是**通用**的(测循环不变量,不测具体业务)。
3. **结构化失败遥测 + 自 soak 回归门**:每次循环退出落一条结构化原因码;新增 `Scripts/soak-e2e.sh`(扩 `smoke-e2e.sh`):真模型连续跑 N 个随机任务 M 小时,任一不变量破/wedge 即 FAIL。**超越点**:把它接成"灵枢自检"——`schedule_task` 定时自跑基准+soak,回归就推送告警(CC/Codex 不自 soak)。

**改哪些文件:** `Sources/LingShuAgentLoop.swift`(不变量断言 + 原因码)、新增 `Tests/LingShuMacTests/AgentLoopFuzzTests.swift`、扩 `LiveSoakTests`、新增 `Scripts/soak-e2e.sh`。
**验收:** Fuzz 单测全绿(随机种子可复现);soak 脚本真模型 ≥1h 零 wedge;故意注入一个粘滞标志能被不变量单测抓到。

### 差距 2·薄基线(强脑→真薄 harness)

**现状:** `harnessKnobPrefix` 在系统提示前加"放权"句,**二元开关**(脑力分≥85 放权,否则不放);验收门(独立 LLM verifier 调用)、长系统提示、强制 update_plan 仍每回合在跑。基线没真薄,且二元静态分数切**太脆**(98 分因一道字符级偏题就被打回厚)、**太粗**(能力是连续谱)、**轴错**(该看"这道任务的确定性结果",不是"这脑总体强不强的静态快照")。

**通用方案(不要静态分数二元切,要"默认薄 + 反应式加厚 + 分数当连续先验"):**
1. **默认所有任务走最薄(Rung0)**——升级阶梯 `LingShuCapabilityEscalation` 本就如此:起步最薄,**只有确定性门失败/停滞/撞顶**才当任务内升级脚手架。所以"加厚"是**反应式、按这次实际结果**,不需要全局"强不强"判断。
2. **脑力分 = 连续先验 + 遥测,不是开关**:用它定**起步档**(强脑起步更薄/提示更精简、弱脑起步带 plan 提示),分级连续(不是 85 一刀切);之后一律由真实确定性结果驱动加厚。
3. **那次"贵的 LLM verifier"按交付物类型 + 确定性门结果 gate,不按分数**:**代码且测试跑绿+运行不崩 → 跳过 LLM verifier**(确定性门已定正确性,LLM 自评冗余);**主观交付物(PPT/文档,无确定性门)→ 才跑 LLM verifier**。这是 per-交付物 的通用判据,省掉"always-on 贵调用"且不靠脆阈值。
4. **强制 update_plan 降为软提示**(它已在 `optionalScaffoldTools`):让模型自决;只在**确定性停滞检测**命中时才催"该规划了"。

**铁律:省的永远只是"贵的 LLM 自评 + 程序性提示",确定性门(测试/运行/隐藏用例/产出物存在/循环不变量)一律不省**——正确性不打折。

**改哪些文件:** `Sources/State/LingShuState+BrainScore.swift`(脑力分→连续起步先验,**删二元 harnessKnobPrefix 阈值**)、`Sources/State/LingShuState+AgentBackbone.swift`(系统提示按起步档选 + update_plan 软化)、`Sources/State/LingShuState+DeliveryReview.swift`/`+AgentAcceptance.swift`(**按交付物类型 gate LLM verifier**:代码确定性门过则跳过)。
**验收:** 纯逻辑单测(代码+测试绿→不调 LLM verifier;主观交付物→调;脑力分→连续起步档,无 85 硬跳变);.app E2E:代码任务往返/延迟明显降且确定性门仍拦坏交付;一道偏题不再把强脑打回厚。
**超越点:** **自适应 + 反应式 harness**——CC/Codex 是固定薄(弱模型上裸奔);灵枢**默认薄、按真实结果反应式加厚、按交付物 gate 贵验收**,跨模型谱系上限更高且更省。这是真正的超越。

### 差距 3·文件编辑精度(apply_patch 式多处编辑)

**现状:** 只有 `edit_file`(`LingShuEditReplacer.replace` 单处 old→new)。大改要多次往返。

**通用方案:** 新增**通用** `apply_patch` 工具:一次调用含**多文件、多 hunk**,每 hunk 带上下文锚定;**事务性**(全成或全不改);应用后自动 re-read 校验。复用 `LingShuEditReplacer` 做逐 hunk 替换。格式用通用 unified-diff 或 Codex apply_patch 信封(择一,通用)。
**改哪些文件:** `Sources/Support/LingShuEditReplacer.swift`(加多 hunk 解析/应用,纯逻辑)、`Sources/Infrastructure/LingShuFunctionCalling.swift`(加 catalog 条目)、`Sources/Services/LingShuToolExecutor.swift`(`LingShuLocalToolExecutor` 加 apply_patch 分支)。
**验收:** 纯逻辑单测(多 hunk 应用/锚定失败回滚/事务性);E2E 让模型一次改多处。
**超越点:** 应用后**自动跑受影响测试**确认没改坏(接确定性门)。

### 差距 4·上下文压缩成熟度

**现状:** `compactHistoryIfNeeded` 首版:按**消息条数**(maxHistoryMessages)触发、整段蒸馏。

**通用方案(全通用):** ① 触发改**按估算 token 预算**,不只条数;② 分层保留:系统/seed 永留 + 最近 N 条逐字 + 中段蒸馏;③ 不截断仍被引用的 tool 结果。
**超越点(灵枢独有,务必做):** **知识图谱增强的"近无损"压缩**——蒸馏的同时把被丢弃消息的关键事实 `remember` 进知识图谱(`Sources/Memory/`),需要细节时 `recall` 拉回。CC 的压缩是有损的;灵枢"摘要 + 可检索细节"超越之。通用(任意会话适用)。
**改哪些文件:** `Sources/LingShuAgentLoop.swift`(token 预算触发 + 分层)、接 `Sources/Memory/` 知识图谱。
**验收:** 单测(给定消息序列→压缩后 token 在预算内、最近 N 条逐字保留、关键事实可召回)。

### 差距 5·工具生态 / MCP 广度

**现状:** 有 MCP 连接器(`connectorRegistry`)+ `author_component`(自造工具/感知/执行器)+ `discover_skill`(联网找技能)。生态广度/打磨不如 CC/Codex 的海量 MCP。

**通用方案(都通用):** ① MCP 接入零摩擦:可信 registry 浏览 + 一键连;② 打磨 `author_component`/`discover_skill` 的自造路径(已是通用机制)。
**超越点:** **从 API 文档自动合成工具**——给一个 OpenAPI/文档 URL,大脑 `author_component` 出一条带 schema 的 typed 工具(通用,复用现成自编外围机制)。
**改哪些文件:** `Sources/State/LingShuState+RemoteConnection.swift`/连接器侧、`Sources/State/LingShuState+ComponentAuthoring.swift`。
**验收:** E2E 接一个真 MCP server 调通;给一个公开 API 文档自动造出可调工具。

### 差距 6·子代理/并行编排深度

**现状:** `LingShuAgentOrchestrator`(spawn + 统一账本 + acceptanceHook 复用主验收)已是真并行隔离。

**通用方案(通用):** 加**子任务依赖 DAG**(声明 A→B 依赖,拓扑调度)+ **失败重试/隔离** + **结果聚合**。复用现有 orchestrator。
**改哪些文件:** `Sources/LingShuAgentOrchestrator.swift`。
**验收:** 单测(DAG 拓扑/失败重试/聚合);E2E 多子任务带依赖跑通。

### 差距 7·强脑延迟

**现状:** 常驻感知/验收门/重提示带来额外往返。
**通用方案:** 大部分被**差距 2(thin profile)** 覆盖;另加**独立工具调用并行化**(一回合多个无依赖工具并发执行)+ 结果缓存。通用。
**改哪些文件:** `Sources/LingShuAgentLoop.swift`(并行 tool 执行)。
**验收:** 单测(多无依赖工具并发);E2E 延迟对比。

---

## 3. 执行策略(不是串行 P0→P5,是"先架网 → 并行追平 → 棘轮 → 常驻")

**鲁棒性不是一期,是永不收工的常驻闸门。** 正确顺序:

1. **第一步:架网(差距1 的基建,小而关键,必须先有)** —— 循环**不变量断言** + `AgentLoopFuzzTests`(属性/混沌测试,脱网可 CI) + `Scripts/soak-e2e.sh`(真模型长跑)。**它不是"测一遍就完",是其余所有改动的 CI 闸门。** 理由:**边做边测 ≫ 做完再测**——没网就全面追平会变成"5 个特性堆完才开 fuzz,失败无法归因 + 在潜藏 bug 上盖新特性"的泥潭。
2. **然后:并行全面追平(差距 2-7,互相基本独立,可多线程/多 agent 并行)** —— 每项落地**都必须过网**(不变量/fuzz/soak 全绿才算数):
   - 差距2 薄基线自适应(默认薄+反应式加厚+按交付物 gate 贵验收)—— **收益最大 + 超越点**。
   - 差距3 apply_patch 多 hunk 事务编辑 —— 独立、立竿见影。
   - 差距4 压缩成熟 + 知识图谱无损召回 —— 超越点。
   - 差距6/7 编排 DAG + 工具并行。  · 差距5 MCP 零摩擦 + 文档→工具合成。
3. **棘轮(只升不降)**:每个 fuzz/soak/真机发现的失败 → **固化成一条永久测试**,测试集只增不减。
4. **常驻**:fuzz/soak 进 CI + 灵枢**自 soak/自基准定时自检**(`schedule_task`),回归即告警 —— 这就是"持续测到(逼近)无测可测"。

**诚实上限:** "无测可测"是渐近线(输入空间=任意任务×模型×环境,无限);合成测试到不了 100%,最后 ~10-20% 长尾要真实流量/极端 fuzz。能落地的是"已知不变量穷尽守住 + 新失败自动浮现 + 回归棘轮 + 真实流量尾巴"。

每项:纯逻辑抽函数配单测;`bash Scripts/build-app.sh debug` + MCP 8917 真机 E2E;真假分级标注。**网先在、各项过网、永不收工。**

---

## 4. 复用清单(别重造)

- 循环/不变量:`Sources/LingShuAgentLoop.swift`(`runLoop`/`compactHistoryIfNeeded`/`trimHistoryIfNeeded`/`stuck` 检测)。
- 升级阶梯(失败才加脚手架):`Sources/Services/LingShuCapabilityEscalation.swift`。
- 验收确定性门(thin 档保留):`Sources/State/LingShuState+DeliveryReview.swift`(测试门/运行门)、`+AgentAcceptance.swift`。
- 脑力分/旋钮信号:`Sources/State/LingShuState+BrainScore.swift`、基准 `Sources/Services/LingShuBrainBenchmark.swift`。
- 编辑:`Sources/Support/LingShuEditReplacer.swift`;工具目录/执行器:`Sources/Infrastructure/LingShuFunctionCalling.swift`、`Sources/Services/LingShuToolExecutor.swift`。
- 编排:`Sources/LingShuAgentOrchestrator.swift`。知识图谱:`Sources/Memory/`。
- 测试基线:`LiveSoakTests`/`ExecutionResilienceTests`/`NetworkResumeTests`/`AgentLoopTests`。
- 内核契约(别改坏):`Docs/灵枢内核ABI.md`、`KernelABIContractTests`。架构守卫(文件≤500/≤800):`ArchitectureGuardTests`。

---

## 5. 硬约束(铁律,违反即回退)

1. **通用零定制**:不写关键词清单/任务特判/品牌分支;领域特定只存数据(知识/自编组件/题库)。
2. **薄随脑力**:thin 档只省**贵的 LLM 自评**,**绝不省确定性门**(测试/运行/隐藏用例/不变量)——正确性不打折。
3. **安全红线不动**:不可逆/对外先确认、未审代码不静默执行——不随旋钮放松、只增不减。
4. **真凭据 + 真假分级(✅/⚠️/❌),零假 demo**,交付附实测证据。
5. **以 .app 运行**(`open dist/灵枢.app`),改源码必重建;MCP 8917 验证;日志 `/tmp/lingshu-control.log`。
6. **模块化**:纯逻辑抽函数配单测;Swift 文件 ≤500(状态扩展)/≤800(基础设施),`ArchitectureGuardTests` 守;改完同步 `Docs/架构速查手册.md`。
7. **内核 ABI 不破坏**:加内部方法可以,改五协议冻结面要升版本 + 过契约测试。

---

## 6. 一句话总纲

**同强脑下追平 Codex/Claude Code,核心是把 harness 做到"鲁棒到隐身、强脑时薄到让开、确定性门不放手";超越点是"自适应 harness(随脑薄厚)+ 知识图谱无损压缩 + 自评测自 soak"——全部通用,领域特定只进数据,安全红线不动。**
