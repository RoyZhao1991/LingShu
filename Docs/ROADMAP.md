# 灵枢落地方案：从 macOS 中枢到"贾维斯"级通用助手

> 2026-06-11 制定。基于对当前代码（67 个源文件，约 2.1 万行）的完整审查。
> 终极目标：一个常驻、多模态、有记忆、能自主推进任务的通用 agent 中枢。

## 一、现状评估

### 已经成立的部分

| 能力 | 现状 | 位置 |
| --- | --- | --- |
| 中枢编排骨架 | 主线程内核 + 路由规划 + 能力调度的分层已成型 | `Sources/LingShuMainThreadRuntime.swift`、`LingShuRoutePlanner.swift`、`LingShuAgentScheduler.swift` |
| 模型通道 | HTTP 模型网关（Responses/Chat/Anthropic 多格式 + 前缀缓存 + 流式）；大脑当前 DeepSeek。codex/claude 不再是模型通道，改为 agent 插件接入 | `LingShuModelGateway.swift`、`LingShuModelChannel.swift`、`Plugins/LingShuAgentPlugin*.swift` |
| 任务可追溯 | 任务执行记录（消息/产出物/血缘关联）+ 归档 | `LingShuTaskExecutionJournal.swift` |
| 记忆分层 | 热/冷聊天历史 + 主线程快照 + 记忆服务雏形 | `Services/Memory/`、`LingShuMemoryService.swift` |
| 语音/视觉入口 | 本地 ASR、TTS、摄像头观测、感知线程协调 | `Services/VoiceIOManager.swift`、`VisionIOManager.swift`、`Services/Perception/` |
| 边界测试 | 86 个测试覆盖分层边界与存储语义 | `Tests/LingShuMacTests/CoreBoundaryTests.swift` |

### 本轮已修复的性能问题（2026-06-11）

1. **持久化风暴**：聊天历史在每次 `chatMessages` 变化（含流式每个 chunk、思考期每秒一次的 `isLoading` 重写）时，同步在主线程做"读冷文件→解码 5000 条→合并排序→pretty JSON 编码→写两个文件"。已改为 0.8 秒防抖 + 后台串行队列 + 冷历史内存缓存。
2. **任务日志双重 IO**：每个流式 chunk 触发"编码 400 条记录写 UserDefaults → 立刻解码读回"。已改为返回归一化结果直接采用，写入移到后台队列，归档加缓存。
3. **每秒全窗重渲染**：1 秒 tick 无条件给多个 `@Published` String 赋相同值。已加变更守卫。
4. **聊天列表非懒加载**：600 条热历史每次刷新全量构建气泡视图。已换 `LazyVStack`。
5. **eventLog 无界增长**：30 处头部插入无上限。已统一收口到 `logEvent`（上限 200）。

### 仍然存在的架构债（按风险排序）

1. **上帝对象** `State/LingShuState.swift`（约 3450 行，65+ `@Published`，96 个方法）：所有视图观察同一个对象，任何字段变化都使整个界面失效重算；业务编排、UI 状态、网络回调、持久化全部纠缠在一起，是后续每一项能力扩展的摩擦来源。
2. **GCD 与 actor 混用**：`DispatchQueue.global().async` + `DispatchQueue.main.async` 手工跳线程的写法遍布模型调用路径（`LingShuState.swift` 内 16 处），取消、超时、背压全靠手写标志位（`missionRunID`、`probeRunID` 防串扰），脆弱且难测。
3. **UserDefaults 当数据库**：任务日志（80 活跃 + 320 归档，每条 ≤140 消息）、内核快照都存 UserDefaults。它整库写盘、无查询能力、容量上限约 4MB，撑不起"长期记忆"。
4. **进程级模型桥接**：每次调用 spawn 一个 Codex CLI 进程、信号量等待退出。延迟高、无法真正双工流式、无法多通道并发复用。
5. **能力即硬编码**：路由规划、能力节点、外部 agent 都在 Swift 源码里静态注册，新能力 = 改中枢代码，违背 `Docs/ARCHITECTURE.md` 自己定下的"能力节点独立演进"原则。

## 二、目标拆解：贾维斯 = 五个可验收的系统性质

把"类似贾维斯"翻译成工程性质，每一项都可度量：

1. **常驻与可靠**：7×24 运行，崩溃自恢复，任何任务可追溯、可中断、可续作。
2. **多模态实时回路**：语音唤醒→流式 ASR→中枢判断→流式 TTS 的端到端延迟 < 1.5s；视觉观测可作为对话上下文。
3. **持久记忆**：跨会话记住人、事、偏好、承诺；检索靠语义而不是字符串匹配。
4. **自主任务执行**：给目标而非指令；规划→执行→验证→交付闭环，失败会自行重试或求助。
5. **主动性与安全**：能基于时间/事件主动开口，但所有高风险动作过权限裁决与人工确认。

## 三、分期路线

### Phase 0 — 地基加固（1~2 周）✅ 部分完成

- [x] 仓库独立（已从 ReceiptVault 仓库拆出，独立 git 历史）。
- [x] 持久化与渲染热路径优化（见上）。
- [ ] CI：GitHub Actions 跑 `swift build` + `swift test`，main 分支保护。
- [ ] 把 `swift-format` / SwiftLint 接入，固化代码风格。

### Phase 1 — 拆解上帝对象，确立并发模型（2~4 周）

**目标：`LingShuState` 降到 < 500 行，只剩 UI 状态聚合。**

按"变化频率 + 关注点"拆成独立 `ObservableObject`（或迁到 `@Observable` 宏，自动按属性粒度追踪依赖）：

| 新对象 | 承接内容 | 来源行数 |
| --- | --- | --- |
| `ChatSessionModel` | chatMessages、输入、流式更新、历史分页 | ~600 |
| `MissionRuntimeModel` | coreState、计时器、runtimePhase、trace | ~500 |
| `ModelGatewayModel` | provider/endpoint/auth/探活/会话池状态 | ~800 |
| `TaskJournalModel` | 任务记录、线程、队列 | ~400 |
| `PreferencesModel` | 语音唤醒词、开关类设置 | ~150 |

并发模型统一规则：

- 服务层全部 actor 化或 `Sendable` 化，删除手写 `DispatchQueue` 跳线程；模型调用改 `async/await` + `Task` 取消传播，替代 `missionRunID` 串扰防护。
- 每秒 tick 降级：思考/执行计时用 `TimelineView` 或局部小视图自己订阅，禁止 tick 触碰全局对象。

**验收**：现有 86 测试全绿 + 新增各 Model 的单元测试;Instruments 录制空闲 60 秒,主窗口 body 求值次数 < 5。

### Phase 2 — 存储升级：从文件/UserDefaults 到结构化记忆底座（2~3 周）

- 任务日志、聊天历史迁 **SQLite**（GRDB 或原生 SQLite + FTS5 全文索引），一次性迁移器负责从 UserDefaults/JSON 导入。
- 记忆三层定型：
  - **工作记忆**：当前任务上下文（内存）；
  - **情景记忆**：对话与任务历史（SQLite + FTS5）；
  - **语义记忆**：事实/偏好/承诺，带 embedding 向量（先用 `NLEmbedding` 本地向量，后接模型 embedding API），余弦检索。
- 记忆写入策略：任务结束时由中枢做"反思摘要"写入语义记忆，而不是裸存原文。

**验收**："上周让你查的那件事"这类指代可检索命中；万条历史下检索 < 50ms。

### Phase 3 — 模型网关重构：常驻双工通道（3~4 周）

- `LingShuModelGateway` 抽象成协议：`OpenAICompatChannel`、`AnthropicAPIChannel`、`LocalModelChannel`（Ollama/MLX）等实现，按任务特征路由——判断类走快通道小模型，执行类走强模型。（注：codex/claude 已从模型通道剥离，改为 agent 插件，见 `Plugins/LingShuAgentPlugin*.swift`。）
- 心跳/探活迁入通道内部，对中枢只暴露 `ChannelHealth` 状态流。

**验收**：首 token 延迟（本地路由判断）< 800ms；通道断开自动重连且任务不丢。

### Phase 4 — 语音/视觉实时回路（与 Phase 3 并行，3~4 周）

- 语音管线改全双工状态机：唤醒词（已有）→ 流式 ASR 增量上屏 → 句末检测提前送中枢 → TTS 分句流式播报，支持**打断**（用户开口即停播）。
- 视觉观测从"6 秒采样进 trace"升级为：变化检测 + 关键帧描述进工作记忆，按需供中枢引用。
- 端到端延迟埋点：麦克风停顿→首句播报，目标 < 1.5s。

### Phase 5 — 自主任务执行闭环（4~6 周）

- 把现有"路由→分派"升级为 **规划-执行-验证循环**：中枢生成可检查的计划（步骤+验收标准）→ 能力节点执行 → 验证器对照验收标准检查产物 → 不达标自动修正或上报。复用现有 `LingShuTaskExecutionJournal` 做全程审计。
- 能力节点插件化：定义能力清单（manifest：名称/输入输出/权限需求/风险级），运行时注册，替代源码硬编码；外部 agent 经 `LingShuExternalAgentGateway` 走同一 manifest。
- 权限裁决落地：`LingShuPermissionPolicy` 从静态规则升级为"风险级 × 资源域"矩阵，高风险动作必经人工确认（已有 `requireHumanApproval` 开关，接到真实拦截点）。

**验收**：「帮我把这份数据整理成周报发到桌面」级别的多步任务，无人值守完成率 > 80%，全程审计可回放。

### Phase 6 — 常驻与主动性（2~3 周）

- 菜单栏常驻 + LaunchAgent 开机自启；主窗口关闭不退出。
- 触发器系统：时间（提醒/例行任务）、事件（文件变化、日历、剪贴板）、状态（任务完成/失败）→ 中枢决定是否开口。
- 主动性约束：打扰预算（每小时上限）、勿扰时段、所有主动行为进 eventLog 可审计。

## 四、工程纪律（贯穿全程）

1. **每个 Phase 收口标准**：测试全绿 + 性能指标达标 + `Docs/ARCHITECTURE.md` 同步更新。
2. **测试策略**：Domain/Service 层单测先行；中枢编排用录制回放式集成测试（假通道注入脚本化模型响应）。
3. **可观测**：统一 `os_log` 分类（中枢/通道/记忆/感知），关键路径打 signpost，Instruments 可直接看回路延迟。
4. **隐私与安全**：所有记忆/历史只存本地（`~/Library/Application Support/LingShu`）；API key 迁 Keychain（当前 `@Published var apiKey` 为明文内存 + 无持久化，迁移时一并处理）；麦克风/摄像头状态栏常显。

## 五、优先级速查

```
现在就做   : Phase 1 拆 LingShuState（一切后续工作的前置）
并行准备   : CI + SQLite 选型验证（GRDB spike）
先不要做   : 插件市场、移动端、云同步——常驻回路没稳定之前都是干扰
```
