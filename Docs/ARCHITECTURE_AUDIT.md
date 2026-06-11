# 架构审查报告（2026-06-11）

对照 `Docs/ARCHITECTURE.md` 标准对全代码做的一次完整审查。结论：**层边界干净，无越层调用；主要债务是 god object 与少量文件组织/体积问题，本轮已修可安全修复的部分。**

## 一、层边界合规性 ✅

| 检查项 | 结果 |
| --- | --- |
| Views 直接调用 Infrastructure（CodexBridge / URLSession / Process） | 无（守卫测试 `testViewsDoNotDirectlyCallInfrastructureAdapters` 通过） |
| Domain 依赖网络 / 文件系统 | 无 |
| Domain 依赖 UI | 仅 `Color` 值类型（标准允许的轻量 UI 值对象） |
| App 入口 `LingShuMac.swift` 只做启动 | 是（<200 行，不引用模型/网关，守卫测试通过） |
| 模型供应商差异封装在适配层 | 是（`LingShuModelGateway` / `LingShuCloudPerceptionClient` / 感知 provider 协议） |
| 实时感知三层分离（采集 / 本地解析 / 感知网关） | 是；云模型经 `LingShuRealtimePerceptionGateway` 的 provider 注册接入，未硬编码进麦克风/摄像头服务 |

## 二、本轮已修复

1. **CodexBridge.swift 929 行 > 800 硬上限** → 拆成 4 个文件：
   - `CodexBridgeModels.swift`（命令结果/探活报告/路由载荷/权限模式等数据类型）
   - `CodexDiagnosticLogFilter.swift`（诊断日志过滤）
   - `CodexProcessSupport.swift`（子进程取消句柄 + 流式捕获）
   - `CodexBridge.swift` 收敛到 637 行，只剩桥接执行逻辑。
   - 新增守卫测试 `testInfrastructureFilesStayBelowHardSplitThreshold` 锁定。
2. **两个视图文件散落在 `Sources/` 根目录** → 移入 `Sources/Views/`（`LingShuExecutionConsoleView`、`LingShuTaskExecutionRecordViews`）；新增守卫测试 `testViewFilesLiveUnderViewsFolder`。
3. （前序）会话上下文丢失、每秒重渲染、持久化风暴、死代码已在此前提交修复。

## 三、效率审查

- 早前已修：聊天/任务日志的同步持久化风暴（改后台串行队列 + 防抖 + 缓存）、每秒 tick 全窗失效（加变更守卫 + TimelineView 局部刷新）、600 条气泡非懒加载（LazyVStack）。
- 本轮复查：`callChainAgents`、`agentRuntimeCounts`、`firstIndex(where:)` 等热路径均为 O(n) 且 n 很小（agent 11、任务记录 ≤80），非真实瓶颈，不做过度优化。
- 模型调用全部 `async/await` + 后台队列，主线程不阻塞。

## 四、待办债务（按优先级，需要专门迭代）

1. **god object `LingShuState`（约 3470 行）— 最大债务。** 标准明确要求继续拆成更小的 store/coordinator。已拆出 `+ChatHistory / +Conversation / +Attachments / +TaskExecution / +RemoteConnection` 等扩展，主文件压在 3500 行守卫线内。下一步建议按职责拆出独立 store：
   - `ChatSessionStore`（chatMessages + 输入 + 流式）
   - `MissionRuntimeStore`（coreState + 计时 + trace）
   - `ModelGatewayStore`（provider/auth/探活/会话池）
   - `TaskJournalStore`（任务记录/线程/队列）
   这是 `Docs/ROADMAP.md` 的 Phase 1，工作量大、需独立迭代与回归，不宜在功能改动里顺带做。
2. **根目录编排文件归层**：`LingShuModelGateway`、`LingShuRemoteSessionPool`、`LingShuRemoteModelClient`、`LingShuRemoteConnectionHealth`、`LingShuExternalAgent*`、`LingShuMemoryRepository`、`LingShuTaskExecutionJournal` 宜归入 `Infrastructure/`；`LingShuAgentScheduler`、`LingShuRoutePlanner`、`LingShuExecutionCoordinator`、`LingShuMainThreadRuntime` 等编排器宜归入 `Services/` 或新建 `Orchestration/`。纯文件移动、低风险，但churn 大，建议单独一个「目录归层」提交完成，避免与功能改动混在一起。
3. **存储底座升级**：任务日志仍用 UserDefaults，聊天历史用 JSON 文件——长期应迁 SQLite + FTS5（ROADMAP Phase 2）。

## 五、结论

当前架构**符合标准的层次约束，无越层违规**；体积与组织类问题本轮已修可安全修复者。剩余的 god object 拆分与目录归层是规模较大、需要独立回归的重构，已在本报告与 ROADMAP 中登记，建议作为专门迭代推进，而不是在功能开发中夹带，以控制回归风险。
