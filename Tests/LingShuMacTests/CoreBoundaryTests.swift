import XCTest
@testable import LingShuMac

final class CoreBoundaryTests: XCTestCase {
    func testLocalIntentResolverAnswersCurrentTimeWithoutModelRouting() {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 10,
            hour: 8,
            minute: 41
        ))!

        let answer = LingShuLocalIntentResolver.answer(
            for: "现在几点了",
            now: now,
            timeZone: timeZone
        )

        XCTAssertEqual(answer, "现在是 08:41。")
    }

    func testLocalIntentResolverAnswersCurrentDateWithoutModelRouting() {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 10,
            hour: 8,
            minute: 41
        ))!

        let answer = LingShuLocalIntentResolver.answer(
            for: "今天几号",
            now: now,
            timeZone: timeZone
        )

        XCTAssertEqual(answer, "今天是 2026年6月10日，星期三，现在 08:41。")
    }

    func testLocalIntentResolverIgnoresNonDeterministicRequests() {
        XCTAssertNil(LingShuLocalIntentResolver.answer(for: "帮我设计一个任务调度架构"))
    }

    func testRemoteSessionPoolReusesWarmCodexRoutingSession() {
        let defaults = UserDefaults(suiteName: "lingshu.remote-session.tests.\(UUID().uuidString)")!
        let pool = LingShuRemoteSessionPool(defaults: defaults, maxHotSessions: 4, warmTTL: 600)
        let now = Date()

        let coldLease = pool.lease(
            provider: "Codex Auth",
            model: "gpt-5.5",
            purpose: .mainRouting,
            contextKey: "main-session",
            workingDirectory: "/tmp/project",
            permissionBoundary: "sandbox",
            endpoint: "codex://local-cli",
            protocolName: "Codex CLI",
            localContextSummary: "主线程摘要",
            now: now
        )
        XCTAssertFalse(coldLease.isWarm)
        XCTAssertEqual(coldLease.contextMode, .commandResume)

        pool.resolveNativeSession(
            lease: coldLease,
            nativeSessionID: "codex-session-1",
            localContextSummary: "更新后的主线程摘要",
            now: now.addingTimeInterval(1)
        )

        let warmLease = pool.lease(
            provider: "Codex Auth",
            model: "gpt-5.5",
            purpose: .mainRouting,
            contextKey: "main-session",
            workingDirectory: "/tmp/project",
            permissionBoundary: "sandbox",
            endpoint: "codex://local-cli",
            protocolName: "Codex CLI",
            now: now.addingTimeInterval(2)
        )

        XCTAssertTrue(warmLease.isWarm)
        XCTAssertTrue(warmLease.canResumeNativeSession)
        XCTAssertEqual(warmLease.nativeSessionID, "codex-session-1")
    }

    func testRemoteSessionPoolSeparatesExecutionSessionsByTaskContext() {
        let defaults = UserDefaults(suiteName: "lingshu.remote-session.tests.\(UUID().uuidString)")!
        let pool = LingShuRemoteSessionPool(defaults: defaults, maxHotSessions: 4, warmTTL: 600)
        let now = Date()

        let first = pool.lease(
            provider: "Codex Auth",
            model: "gpt-5.5",
            purpose: .taskExecution,
            contextKey: "task-a",
            workingDirectory: "/tmp/project",
            permissionBoundary: "sandbox",
            endpoint: "codex://local-cli",
            protocolName: "Codex CLI",
            now: now
        )
        pool.resolveNativeSession(lease: first, nativeSessionID: "task-session-a", now: now.addingTimeInterval(1))

        let second = pool.lease(
            provider: "Codex Auth",
            model: "gpt-5.5",
            purpose: .taskExecution,
            contextKey: "task-b",
            workingDirectory: "/tmp/project",
            permissionBoundary: "sandbox",
            endpoint: "codex://local-cli",
            protocolName: "Codex CLI",
            now: now.addingTimeInterval(2)
        )

        XCTAssertFalse(second.isWarm)
        XCTAssertNil(second.nativeSessionID)
    }

    func testRemoteConnectionPolicyProbesOnColdStartAndUsesShortReconnectInterval() {
        let policy = LingShuRemoteConnectionPolicy(probeInterval: 60, reconnectInterval: 15, failureThreshold: 3)
        let now = Date()

        XCTAssertTrue(policy.shouldProbe(
            now: now,
            lastProbeAt: nil,
            isProbeInFlight: false,
            hasActiveModelCall: false,
            isGatewayConnected: true,
            consecutiveFailures: 0
        ))

        XCTAssertFalse(policy.shouldProbe(
            now: now.addingTimeInterval(10),
            lastProbeAt: now,
            isProbeInFlight: false,
            hasActiveModelCall: false,
            isGatewayConnected: true,
            consecutiveFailures: 1
        ))

        XCTAssertTrue(policy.shouldProbe(
            now: now.addingTimeInterval(16),
            lastProbeAt: now,
            isProbeInFlight: false,
            hasActiveModelCall: false,
            isGatewayConnected: true,
            consecutiveFailures: 1
        ))
    }

    func testRemoteConnectionPolicyMarksDisconnectedAfterConsecutiveFailures() {
        let policy = LingShuRemoteConnectionPolicy(probeInterval: 60, reconnectInterval: 15, failureThreshold: 3)

        XCTAssertEqual(
            policy.phase(isProbeInFlight: false, isGatewayConnected: true, consecutiveFailures: 0, hasSuccessfulProbe: true),
            .warm
        )
        XCTAssertEqual(
            policy.phase(isProbeInFlight: false, isGatewayConnected: true, consecutiveFailures: 1, hasSuccessfulProbe: true),
            .reconnecting
        )
        XCTAssertEqual(
            policy.phase(isProbeInFlight: false, isGatewayConnected: true, consecutiveFailures: 3, hasSuccessfulProbe: true),
            .disconnected
        )
    }

    func testRemoteSessionAdapterKeepsOpenAICompatibleModelsClientManaged() {
        let profile = LingShuRemoteModelAdapterProfile.resolve(
            provider: "DeepSeek",
            endpoint: "https://api.deepseek.com/v1/chat/completions",
            protocolName: "OpenAI 兼容"
        )

        XCTAssertEqual(profile.contextMode, .clientManagedContext)
        XCTAssertTrue(profile.supportsStreaming)
        XCTAssertFalse(profile.supportsNativeContinuation)
    }

    func testTaskExecutionRecordCapturesAgentStyleProgress() {
        var record = LingShuTaskExecutionRecord.create(prompt: "帮我写一个简单的 web 爬虫")

        record.append(
            actor: "规划",
            role: "规划",
            kind: .agent,
            text: "先明确目标网站、输出格式和权限边界。"
        )
        record.applyRoute(
            needsAgents: true,
            agents: ["规划", "审议", "执行"],
            summary: "创建任务线程并分派能力节点。"
        )
        record.finish(status: .completed, summary: "已完成一版可运行代码。")

        XCTAssertEqual(record.status, .completed)
        XCTAssertTrue(record.participants.contains("规划"))
        XCTAssertTrue(record.participants.contains("执行"))
        XCTAssertEqual(record.messages.last?.actor, "规划")
        XCTAssertEqual(record.summary, "已完成一版可运行代码。")
    }

    func testTaskExecutionJournalPersistsRecentRecords() throws {
        let defaults = UserDefaults(suiteName: "lingshu.task-record.tests.\(UUID().uuidString)")!
        let journal = LingShuTaskExecutionJournal(defaults: defaults, maxRecords: 2)
        var records: [LingShuTaskExecutionRecord] = []

        let first = LingShuTaskExecutionRecord.create(prompt: "第一个任务")
        var second = LingShuTaskExecutionRecord.create(prompt: "第二个任务")
        second.append(actor: "灵枢", role: "中枢", kind: .result, text: "已完成。")

        journal.upsert(first, into: &records)
        journal.upsert(second, into: &records)
        journal.saveRecords(records)

        let loaded = journal.loadRecords()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains(where: { $0.prompt == "第一个任务" }))
        XCTAssertTrue(loaded.contains(where: { $0.messages.contains(where: { $0.text == "已完成。" }) }))
    }

    func testTaskExecutionJournalArchivesOverflowRecordsForLineageRecall() throws {
        let defaults = UserDefaults(suiteName: "lingshu.task-record.archive.tests.\(UUID().uuidString)")!
        let journal = LingShuTaskExecutionJournal(defaults: defaults, maxRecords: 1, maxArchivedRecords: 4)
        var records: [LingShuTaskExecutionRecord] = []

        let older = LingShuTaskExecutionRecord.create(prompt: "历史任务", now: Date(timeIntervalSince1970: 100))
        var newer = LingShuTaskExecutionRecord.create(prompt: "当前任务", now: Date(timeIntervalSince1970: 200))
        newer.append(actor: "灵枢", role: "中枢", kind: .result, text: "当前任务完成。")

        journal.upsert(older, into: &records)
        journal.upsert(newer, into: &records)
        journal.saveRecords(records)

        XCTAssertEqual(journal.loadRecords().count, 1)
        XCTAssertTrue(journal.loadArchivedRecords().contains(where: { $0.id == older.id }))
    }

    func testChatHistoryStoreRestoresRecentConversationAcrossLaunches() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-chat-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LingShuChatHistoryStore(storageDirectory: directory)
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let messages = [
            ChatMessage(speaker: "你", text: "灵枢，记住这段对话。", isUser: true, createdAt: now.addingTimeInterval(-60)),
            ChatMessage(speaker: "灵枢", text: "我会保留最近三天的热历史。", isUser: false, createdAt: now.addingTimeInterval(-58))
        ]

        store.save(messages, now: now)

        let restored = store.loadInitialHistory(now: now)

        XCTAssertEqual(restored.messages.map(\.text), messages.map(\.text))
        XCTAssertFalse(restored.hasMoreColdHistory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.hotHistoryFileURL.path))
    }

    func testChatHistoryStoreArchivesOlderMessagesForTransparentColdRecall() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-chat-history-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LingShuChatHistoryStore(storageDirectory: directory, hotRetention: 3 * 24 * 60 * 60)
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let oldMessage = ChatMessage(
            speaker: "你",
            text: "五天前的讨论",
            isUser: true,
            createdAt: now.addingTimeInterval(-5 * 24 * 60 * 60)
        )
        let recentMessage = ChatMessage(
            speaker: "灵枢",
            text: "今天的回复",
            isUser: false,
            createdAt: now.addingTimeInterval(-120)
        )

        store.save([oldMessage, recentMessage], now: now)

        let initial = store.loadInitialHistory(now: now)
        XCTAssertEqual(initial.messages, [recentMessage])
        XCTAssertTrue(initial.hasMoreColdHistory)

        let coldPage = store.loadColdHistory(
            before: initial.messages.first,
            existingIDs: Set(initial.messages.map(\.id))
        )

        XCTAssertEqual(coldPage.messages, [oldMessage])
        XCTAssertFalse(coldPage.hasMoreColdHistory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.coldHistoryFileURL.path))
    }

    func testTaskExecutionRecordKeepsRelatedHistoricalFlow() throws {
        let previous = LingShuTaskExecutionRecord.create(prompt: "帮我写一个简单的 web 爬虫")
        var current = LingShuTaskExecutionRecord.create(prompt: "继续刚才的爬虫任务")

        current.linkRelatedRecord(previous.id)
        current.linkRelatedRecord(previous.id)

        XCTAssertEqual(current.relatedRecordIDs, [previous.id])

        let data = try JSONEncoder().encode(current)
        let decoded = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: data)

        XCTAssertEqual(decoded.relatedRecordIDs, [previous.id])
    }

    func testTaskExecutionRecordPersistsArtifacts() throws {
        var record = LingShuTaskExecutionRecord.create(prompt: "生成项目文档")

        record.appendArtifact(
            title: "需求说明书",
            location: "file:///tmp/requirements.md",
            producer: "远程规划 agent"
        )
        record.appendArtifact(
            title: "重复产出物",
            location: "file:///tmp/requirements.md",
            producer: "远程规划 agent"
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: data)

        XCTAssertEqual(decoded.artifacts.count, 1)
        XCTAssertEqual(decoded.artifacts.first?.title, "需求说明书")
    }

    func testCodexRetryDiagnosticsAreFilteredFromUserVisibleOutput() {
        let diagnostic = "2026-06-10T01:55:01.699073Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (1/5 in 189ms)..."
        let rawOutput = """
        灵枢回复第一行
        \(diagnostic)
        灵枢回复第二行
        """

        XCTAssertTrue(CodexDiagnosticLogFilter.isInternalDiagnosticLine(diagnostic))
        XCTAssertEqual(CodexDiagnosticLogFilter.diagnosticSummary(from: diagnostic), diagnostic)
        XCTAssertEqual(
            CodexDiagnosticLogFilter.userVisibleText(from: rawOutput),
            "灵枢回复第一行\n灵枢回复第二行"
        )
    }

    @MainActor
    func testGuardStreamsUpdateHealthWithoutPollutingExecutionTrace() {
        let state = LingShuState()
        let initialTraceCount = state.executionTrace.count
        let diagnostic = "2026-06-10T01:55:01.699073Z  WARN codex_core::responses_retry: stream disconnected - retrying sampling request (1/5 in 189ms)..."

        state.appendCodexStream("__LINGSHU_HEARTBEAT__ LINGSHU_HEALTH_OK", actor: "主线程守护")
        state.appendCodexStream("LINGSHU_HEALTH_OK", actor: "主线程守护")
        state.appendCodexStream(diagnostic, actor: "远端会话守护")

        XCTAssertEqual(state.executionTrace.count, initialTraceCount)
        XCTAssertEqual(state.modelHeartbeatSource, "远端会话守护")

        state.appendCodexStream("真实执行输出", actor: "执行模型")
        XCTAssertEqual(state.executionTrace.count, initialTraceCount + 1)
        XCTAssertEqual(state.executionTrace.last?.detail, "真实执行输出")
    }

    func testPermissionPolicyKeepsLightweightDevelopmentInSandbox() {
        let policy = LingShuPermissionPolicy()

        let decision = policy.decide(
            intent: .lightweightDevelopment,
            codexMode: .fullAccess,
            requireHumanApproval: true
        )

        XCTAssertEqual(decision.sandboxMode, .sandbox)
        XCTAssertFalse(decision.allowsFileMutation)
        XCTAssertFalse(decision.requiresHumanApproval)
        XCTAssertTrue(decision.boundary.contains("轻量开发任务"))
    }

    func testPermissionPolicyAllowsProjectExecutionWithConfiguredBoundary() {
        let policy = LingShuPermissionPolicy()

        let decision = policy.decide(
            intent: .projectExecution,
            codexMode: .fullAccess,
            requireHumanApproval: true
        )

        XCTAssertEqual(decision.sandboxMode, .fullAccess)
        XCTAssertTrue(decision.allowsFileMutation)
        XCTAssertTrue(decision.requiresHumanApproval)
        XCTAssertTrue(decision.boundary.contains("高风险动作需人工确认"))
    }

    func testModelGatewaySnapshotsCodexAuthConnection() {
        let gateway = LingShuModelGateway()

        let snapshot = gateway.snapshot(
            provider: "Codex Auth",
            model: "gpt-5.5",
            endpoint: "codex://local-cli",
            apiKey: "",
            codexAuthStatus: "已登录",
            codexAuthDetail: "ChatGPT"
        )

        XCTAssertEqual(snapshot.connectionKind, .codexAuth)
        XCTAssertTrue(snapshot.isConnected)
        XCTAssertEqual(snapshot.engineLabel, "Codex Auth / gpt-5.5")
    }

    func testModelGatewayBuildsOpenAICompatibleChatContract() throws {
        let gateway = LingShuModelGateway()

        let contract = try gateway.makeInvocationContract(
            provider: "DeepSeek",
            model: "deepseek-chat",
            endpoint: "https://api.deepseek.com/v1",
            protocolName: "OpenAI 兼容",
            apiKey: "test-key",
            systemPrompt: "你是灵枢。",
            userPrompt: "你好",
            temperature: 0.2,
            stream: false
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertEqual(contract.format, .chatCompletions)
        XCTAssertEqual(contract.url.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(contract.headers["Authorization"], "Bearer test-key")
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual(messages.count, 2)
    }

    func testModelGatewayBuildsResponsesContract() throws {
        let gateway = LingShuModelGateway()

        let contract = try gateway.makeInvocationContract(
            provider: "OpenAI",
            model: "gpt-5.5",
            endpoint: "https://api.openai.com/v1",
            protocolName: "Responses / OpenAI",
            apiKey: "test-key",
            systemPrompt: "你是灵枢。",
            userPrompt: "规划一个任务",
            temperature: 0.1,
            stream: true
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])

        XCTAssertEqual(contract.format, .responses)
        XCTAssertEqual(contract.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(input.first?["role"] as? String, "system")
    }

    func testModelGatewayCarriesResponsesContinuationToken() throws {
        let gateway = LingShuModelGateway()

        let contract = try gateway.makeInvocationContract(
            provider: "OpenAI",
            model: "gpt-5.5",
            endpoint: "https://api.openai.com/v1",
            protocolName: "Responses / OpenAI",
            apiKey: "test-key",
            systemPrompt: "你是灵枢。",
            userPrompt: "继续上一轮",
            temperature: 0.1,
            stream: false,
            continuationToken: "resp_previous_123"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])

        XCTAssertEqual(contract.format, .responses)
        XCTAssertEqual(body["previous_response_id"] as? String, "resp_previous_123")
    }

    func testModelGatewayDecodesCommonChatCompletionResponse() throws {
        let gateway = LingShuModelGateway()
        let data = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "{\\"needsAgents\\":false,\\"summary\\":\\"直接回答\\",\\"directAnswer\\":\\"我是灵枢。\\",\\"finalAnswer\\":\\"我是灵枢。\\",\\"agents\\":[]}"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let text = try gateway.decodeTextResponse(data: data, statusCode: 200)

        XCTAssertTrue(text.contains("\"needsAgents\":false"))
        XCTAssertTrue(text.contains("我是灵枢"))
    }

    func testModelGatewayAllowsLocalOpenAICompatibleModelWithoutAPIKey() throws {
        let gateway = LingShuModelGateway()
        let snapshot = gateway.snapshot(
            provider: "Ollama",
            model: "qwen3",
            endpoint: "http://localhost:11434/v1",
            apiKey: "",
            codexAuthStatus: "未检查",
            codexAuthDetail: ""
        )

        let contract = try gateway.makeInvocationContract(
            provider: "Ollama",
            model: "qwen3",
            endpoint: "http://localhost:11434/v1",
            protocolName: "OpenAI 兼容",
            apiKey: "",
            systemPrompt: "你是灵枢。",
            userPrompt: "你好",
            temperature: 0.2,
            stream: false
        )

        XCTAssertTrue(snapshot.isConnected)
        XCTAssertNil(contract.headers["Authorization"])
        XCTAssertEqual(contract.url.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testModelGatewayBuildsLocalStreamingMultiTurnChatContract() throws {
        let gateway = LingShuModelGateway()

        let contract = try gateway.makeInvocationContract(
            provider: "Ollama",
            model: "qwen3",
            endpoint: "http://localhost:11434/v1",
            protocolName: "OpenAI 兼容",
            apiKey: "",
            systemPrompt: "你是灵枢。",
            userPrompt: "本轮路由判断",
            temperature: 0.2,
            stream: true,
            conversationMessages: [
                .init(role: "user", content: "刚才我们讨论了语音入口。"),
                .init(role: "assistant", content: "我会把语音落成文本。"),
                .init(role: "user", content: "现在继续推进。")
            ]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertEqual(contract.format, .chatCompletions)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["content"] as? String, "现在继续推进。")
        XCTAssertEqual(messages.count, 4)
    }

    func testModelGatewayDecodesStreamingChatCompletionDelta() throws {
        let gateway = LingShuModelGateway()
        let line = #"data: {"choices":[{"delta":{"content":"你好，"}}]}"#

        let delta = gateway.decodeStreamingTextDelta(line: line, format: .chatCompletions)

        XCTAssertEqual(delta, "你好，")
    }

    func testModelGatewayDecodesResponsesStreamingDelta() throws {
        let gateway = LingShuModelGateway()
        let line = #"data: {"type":"response.output_text.delta","delta":"灵枢在。"}"#

        let delta = gateway.decodeStreamingTextDelta(line: line, format: .responses)

        XCTAssertEqual(delta, "灵枢在。")
    }

    func testModelGatewayKeepsCodexAuthOnCodexBridge() {
        let gateway = LingShuModelGateway()

        XCTAssertThrowsError(try gateway.makeInvocationContract(
            provider: "Codex Auth",
            model: "gpt-5.5",
            endpoint: "codex://local-cli",
            protocolName: "Codex CLI",
            apiKey: "",
            systemPrompt: "你是灵枢。",
            userPrompt: "你好",
            temperature: 0.2,
            stream: false
        )) { error in
            XCTAssertEqual(error as? LingShuModelGatewayError, .codexAuthRequiresBridge)
        }
    }

    func testModelGatewayLeavesCloudSDKsToHostAdapters() {
        let gateway = LingShuModelGateway()

        XCTAssertThrowsError(try gateway.makeInvocationContract(
            provider: "AWS Bedrock",
            model: "anthropic.claude-sonnet-4",
            endpoint: "bedrock://us-east-1/default",
            protocolName: "Bedrock SDK",
            apiKey: "unused",
            systemPrompt: "你是灵枢。",
            userPrompt: "你好",
            temperature: 0.2,
            stream: false
        )) { error in
            XCTAssertEqual(error as? LingShuModelGatewayError, .hostAdapterRequired("Bedrock SDK"))
        }
    }

    func testExternalAgentRegistryFiltersEnabledCapabilities() {
        let registry = LingShuExternalAgentRegistry()
        registry.register(.init(
            id: "research.remote",
            displayName: "远程研究 agent",
            capabilities: ["研究", "检索"],
            transport: .a2a,
            endpoint: "https://agent.example/a2a",
            isEnabled: true
        ))
        registry.register(.init(
            id: "disabled.dev",
            displayName: "禁用开发 agent",
            capabilities: ["开发"],
            transport: .http,
            endpoint: "https://agent.example/dev",
            isEnabled: false
        ))

        XCTAssertEqual(registry.snapshot().registered, 2)
        XCTAssertEqual(registry.snapshot().enabled, 1)
        XCTAssertEqual(registry.enabledAgents(matching: "研究").map(\.id), ["research.remote"])
        XCTAssertTrue(registry.enabledAgents(matching: "开发").isEmpty)
    }

    func testExternalAgentInvocationPlanCarriesBoundaryAndHeartbeat() throws {
        let registry = LingShuExternalAgentRegistry()
        registry.register(.init(
            id: "remote.planner",
            displayName: "远程规划 agent",
            capabilities: ["规划", "计划"],
            transport: .a2a,
            endpoint: "https://agent.example/plan",
            isEnabled: true
        ))

        let plan = try XCTUnwrap(registry.makeInvocationPlan(
            capability: "规划",
            prompt: "拆解一个复杂目标",
            contextSummary: "主线程记忆摘要",
            permissionBoundary: "分析/规划任务",
            heartbeatIntervalSeconds: 20
        ))

        XCTAssertEqual(plan.agent.id, "remote.planner")
        XCTAssertTrue(plan.requiresNetwork)
        XCTAssertEqual(plan.request.capability, "规划")
        XCTAssertEqual(plan.request.permissionBoundary, "分析/规划任务")
        XCTAssertEqual(plan.request.heartbeatIntervalSeconds, 20)
    }

    func testExternalAgentGatewayBuildsGenericInvocationContract() throws {
        let registry = LingShuExternalAgentRegistry()
        registry.register(.init(
            id: "remote.executor",
            displayName: "远程执行 agent",
            capabilities: ["执行", "工具"],
            transport: .a2a,
            endpoint: "https://agent.example/invoke",
            isEnabled: true
        ))
        let plan = try XCTUnwrap(registry.makeInvocationPlan(
            capability: "执行",
            prompt: "产出一个通用结果",
            contextSummary: "主线程摘要",
            permissionBoundary: "沙箱执行",
            heartbeatIntervalSeconds: 12
        ))
        let gateway = LingShuExternalAgentGateway()

        let contract = try gateway.makeInvocationContract(for: plan)
        let decodedRequest = try JSONDecoder().decode(LingShuExternalAgentRequest.self, from: contract.body)

        XCTAssertEqual(contract.method, "POST")
        XCTAssertEqual(contract.url.absoluteString, "https://agent.example/invoke")
        XCTAssertEqual(contract.headers["X-LingShu-Agent-ID"], "remote.executor")
        XCTAssertEqual(contract.headers["X-LingShu-Transport"], "a2a")
        XCTAssertEqual(contract.headers["X-LingShu-Heartbeat-Interval"], "12")
        XCTAssertEqual(decodedRequest.permissionBoundary, "沙箱执行")
        XCTAssertEqual(decodedRequest.capability, "执行")
    }

    func testExternalAgentGatewayMapsRemoteStatusWithoutBusinessCoupling() throws {
        let gateway = LingShuExternalAgentGateway()
        let accepted = gateway.decodeResponse(data: Data(), statusCode: 202, requestID: "external-1")
        let rejected = gateway.decodeResponse(data: Data(), statusCode: 403, requestID: "external-2")
        let failed = gateway.decodeResponse(data: Data(), statusCode: 500, requestID: "external-3")

        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(rejected.summary.contains("拒绝"))
    }

    func testExternalAgentGatewayKeepsLocalInvocationInsideHostAdapter() throws {
        let registry = LingShuExternalAgentRegistry()
        registry.register(.init(
            id: "local.memory",
            displayName: "本地记忆 agent",
            capabilities: ["记忆"],
            transport: .local,
            endpoint: "local://memory",
            isEnabled: true
        ))
        let plan = try XCTUnwrap(registry.makeInvocationPlan(
            capability: "记忆",
            prompt: "恢复上下文",
            contextSummary: "主线程摘要",
            permissionBoundary: "只读记忆"
        ))
        let gateway = LingShuExternalAgentGateway()

        XCTAssertThrowsError(try gateway.makeInvocationContract(for: plan)) { error in
            XCTAssertEqual(error as? LingShuExternalAgentGatewayError, .localAgentRequiresHostAdapter("local.memory"))
        }
        XCTAssertEqual(gateway.localAdapterResponse(for: plan).status, .accepted)
    }

    func testHeartbeatPolicyKeepsRunningProcessAliveWithSyntheticHeartbeat() {
        let now = Date()
        let policy = LingShuHeartbeatPolicy(
            syntheticHeartbeatInterval: 15,
            idleTimeout: 180
        )

        XCTAssertTrue(policy.shouldEmitSyntheticHeartbeat(
            processIsRunning: true,
            lastSyntheticHeartbeatAt: now.addingTimeInterval(-16),
            now: now
        ))
        XCTAssertFalse(policy.shouldDeclareHeartbeatLost(
            processIsRunning: true,
            lastActivityAt: now.addingTimeInterval(-120),
            now: now
        ))
    }

    func testHeartbeatPolicyDeclaresLossOnlyForRunningIdleProcess() {
        let now = Date()
        let policy = LingShuHeartbeatPolicy(
            syntheticHeartbeatInterval: 15,
            idleTimeout: 180
        )

        XCTAssertTrue(policy.shouldDeclareHeartbeatLost(
            processIsRunning: true,
            lastActivityAt: now.addingTimeInterval(-181),
            now: now
        ))
        XCTAssertFalse(policy.shouldDeclareHeartbeatLost(
            processIsRunning: false,
            lastActivityAt: now.addingTimeInterval(-181),
            now: now
        ))
    }

    func testCapabilityRoleNormalizesDomainSpecificAliasesToGenericRoles() {
        XCTAssertEqual(LingShuCapabilityRole.normalize("开发节点"), .execution)
        XCTAssertEqual(LingShuCapabilityRole.normalize("测试专家"), .verification)
        XCTAssertEqual(LingShuCapabilityRole.normalize("项目推进"), .planning)
        XCTAssertEqual(LingShuCapabilityRole.normalize("运维巡检"), .monitoring)
        XCTAssertEqual(LingShuCapabilityRole.normalize("A2A 路由"), .routing)
        XCTAssertEqual(LingShuCapabilityRole.normalize("设计部"), .design)
        XCTAssertEqual(LingShuCapabilityRole.normalize("PPT 汇报材料"), .design)
        XCTAssertEqual(LingShuCapabilityRole.normalize("技术方案"), .planning)
    }

    func testAgentSchedulerUsesGenericExecutionRole() {
        let scheduler = LingShuAgentScheduler()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [
                .init(agent: "规划", task: "形成计划"),
                .init(agent: "设计", task: "产出 PPT 结构", mode: "设计"),
                .init(agent: "执行", task: "产出结果"),
                .init(agent: "验证", task: "检查结果")
            ],
            directAnswer: nil,
            finalAnswer: "收到",
            summary: "进入执行"
        )

        let schedule = scheduler.makeSchedule(for: route)

        XCTAssertTrue(schedule.hasExecutionAgent)
        XCTAssertEqual(schedule.dispatches.first(where: { $0.task.agent == "设计" })?.mode, .working)
        XCTAssertEqual(schedule.dispatches.first(where: { $0.task.agent == "执行" })?.mode, .working)
        XCTAssertEqual(schedule.dispatches.first(where: { $0.task.agent == "验证" })?.mode, .verifying)
    }

    func testDialogueAcknowledgementProvidesImmediateReadableIntake() {
        let acknowledgement = LingShuDialogueAcknowledgement()

        let text = acknowledgement.intake(for: "给我做一个介绍你自己的 PPT")

        XCTAssertTrue(text.contains("收到"))
        XCTAssertTrue(text.contains("直接回答"))
        XCTAssertTrue(text.contains("能力节点"))
    }

    func testDialogueAcknowledgementReportsExecutionDispatchForAgentRoute() {
        let acknowledgement = LingShuDialogueAcknowledgement()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [
                .init(agent: "规划", task: "形成结构"),
                .init(agent: "设计", task: "产出 PPT")
            ],
            finalAnswer: "我会处理。"
        )

        let text = acknowledgement.routeReply(for: route, fallback: "收到。", willExecute: true)

        XCTAssertTrue(text.contains("已分派"))
        XCTAssertTrue(text.contains("规划、设计"))
        XCTAssertTrue(text.contains("后台正在执行"))
    }

    func testTaskThreadSchedulerQueuesContinuationOnFocusedRunningThread() {
        let scheduler = LingShuTaskThreadScheduler(maxParallelThreads: 3)
        let focused = LingShuTaskThread.create(
            id: "task-ppt",
            fingerprint: "topic-ppt",
            prompt: "给我做一个介绍灵枢的 PPT",
            memoryStatus: "新任务",
            restored: false,
            recordID: "record-1"
        )
        let lookup = LingShuTaskMemoryLookup(
            taskID: "task-new",
            memoryStatus: "未命中历史任务，创建新任务线程。",
            restored: false,
            hotMatch: nil,
            coldMatch: nil
        )

        let decision = scheduler.decide(
            prompt: "再优化一下封面和目录",
            memoryLookup: lookup,
            activeThreads: [focused],
            focusedThread: focused,
            hasForegroundCall: true
        )

        XCTAssertEqual(decision.action, .enqueueSameThread)
        XCTAssertEqual(decision.threadID, "task-ppt")
    }

    func testTaskThreadSchedulerStartsParallelThreadForIsolatedTaskWithinCapacity() {
        let scheduler = LingShuTaskThreadScheduler(maxParallelThreads: 3)
        let running = LingShuTaskThread.create(
            id: "task-ppt",
            fingerprint: "topic-ppt",
            prompt: "给我做一个介绍灵枢的 PPT",
            memoryStatus: "新任务",
            restored: false,
            recordID: "record-1"
        )
        let lookup = LingShuTaskMemoryLookup(
            taskID: "task-crawler",
            memoryStatus: "未命中历史任务，创建新任务线程。",
            restored: false,
            hotMatch: nil,
            coldMatch: nil
        )

        let decision = scheduler.decide(
            prompt: "写一个 web 爬虫",
            memoryLookup: lookup,
            activeThreads: [running],
            focusedThread: running,
            hasForegroundCall: true
        )

        XCTAssertEqual(decision.action, .startParallel)
        XCTAssertEqual(decision.threadID, "task-crawler")
    }

    func testTaskThreadSchedulerQueuesNewTaskWhenParallelCapacityIsFull() {
        let scheduler = LingShuTaskThreadScheduler(maxParallelThreads: 1)
        let running = LingShuTaskThread.create(
            id: "task-ppt",
            fingerprint: "topic-ppt",
            prompt: "给我做一个介绍灵枢的 PPT",
            memoryStatus: "新任务",
            restored: false,
            recordID: "record-1"
        )
        let lookup = LingShuTaskMemoryLookup(
            taskID: "task-crawler",
            memoryStatus: "未命中历史任务，创建新任务线程。",
            restored: false,
            hotMatch: nil,
            coldMatch: nil
        )

        let decision = scheduler.decide(
            prompt: "写一个 web 爬虫",
            memoryLookup: lookup,
            activeThreads: [running],
            focusedThread: running,
            hasForegroundCall: true
        )

        XCTAssertEqual(decision.action, .enqueueUntilCapacity)
    }

    func testRoutePlannerDecodesMarkdownWrappedRouteAndNormalizesAgents() throws {
        let planner = LingShuRoutePlanner()
        let raw = """
        ```json
        {
          "needsAgents": true,
          "summary": "需要能力协作",
          "finalAnswer": "收到，我来分派。",
          "agents": [
            { "agent": "业务部", "task": " 明确目标 ", "mode": "规划" },
            { "agent": "开发部", "task": "实现爬虫", "mode": "执行" },
            { "agent": "开发", "task": "重复开发任务", "mode": "执行" },
            { "agent": "测试部", "task": "验证输出", "mode": "验收" }
          ]
        }
        ```
        """

        let route = try XCTUnwrap(planner.decodeRoutePayload(from: raw))

        XCTAssertTrue(route.needsAgents)
        XCTAssertEqual(route.agents.map(\.agent), ["规划", "执行", "验证"])
        XCTAssertEqual(route.agents.first?.task, "明确目标")
    }

    func testRoutePlannerKeepsDesignDeliveryAgent() throws {
        let planner = LingShuRoutePlanner()
        let raw = """
        {
          "needsAgents": true,
          "summary": "需要设计交付",
          "finalAnswer": "收到，我来分派。",
          "agents": [
            { "agent": "设计部", "task": "设计三页 PPT 的叙事结构和版式", "mode": "设计" }
          ]
        }
        """

        let route = try XCTUnwrap(planner.decodeRoutePayload(from: raw))

        XCTAssertTrue(route.needsAgents)
        XCTAssertEqual(route.agents.map(\.agent), ["设计"])
        XCTAssertEqual(route.agents.first?.mode, "设计")
    }

    func testRoutePlannerDisablesAgentRouteWhenModelReturnsNoValidAgents() throws {
        let planner = LingShuRoutePlanner()
        let raw = """
        {
          "needsAgents": true,
          "summary": "模型误判",
          "finalAnswer": "收到",
          "agents": [
            { "agent": "未知部门", "task": "处理" },
            { "agent": "执行", "task": "   " }
          ]
        }
        """

        let route = try XCTUnwrap(planner.decodeRoutePayload(from: raw))

        XCTAssertFalse(route.needsAgents)
        XCTAssertTrue(route.agents.isEmpty)
    }

    func testExecutionCoordinatorStartsExecutionForDevelopmentQueue() {
        let coordinator = LingShuExecutionCoordinator()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [.init(agent: "执行", task: "写一个 web 爬虫")]
        )

        let shouldStart = coordinator.shouldStartExecutionThread(
            userPrompt: "帮我写一个简单的 web 爬虫",
            route: route,
            context: .init(
                isDevelopmentQueueRequest: true,
                isProjectExecutionRequest: false,
                isKnowledgeOnlyQuestion: false,
                isCapabilityCollaborationRequest: true
            )
        )

        XCTAssertTrue(shouldStart)
    }

    func testExecutionCoordinatorStartsExecutionForDesignDelivery() {
        let coordinator = LingShuExecutionCoordinator()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [.init(agent: "设计", task: "产出 PPT 设计方案", mode: "设计")]
        )

        let shouldStart = coordinator.shouldStartExecutionThread(
            userPrompt: "帮我做一份三页 PPT 汇报材料",
            route: route,
            context: .init(
                isDevelopmentQueueRequest: false,
                isProjectExecutionRequest: true,
                isKnowledgeOnlyQuestion: false,
                isCapabilityCollaborationRequest: true
            )
        )

        XCTAssertTrue(shouldStart)
    }

    func testExecutionCoordinatorKeepsKnowledgeQuestionOutOfExecution() {
        let coordinator = LingShuExecutionCoordinator()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [.init(agent: "知识", task: "解释概念")]
        )

        let shouldStart = coordinator.shouldStartExecutionThread(
            userPrompt: "解释一下 agent 线程池是什么",
            route: route,
            context: .init(
                isDevelopmentQueueRequest: false,
                isProjectExecutionRequest: false,
                isKnowledgeOnlyQuestion: true,
                isCapabilityCollaborationRequest: false
            )
        )

        XCTAssertFalse(shouldStart)
    }

    func testExecutionCoordinatorAddsNaturalContinuationWhenSatisfactionIsPartial() {
        let coordinator = LingShuExecutionCoordinator()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [.init(agent: "执行", task: "产出代码")]
        )

        let reply = coordinator.postProcessExecutionReply(
            "已给出一个基础爬虫示例。",
            userPrompt: "写一个 web 爬虫",
            route: route,
            context: .init(
                isDevelopmentQueueRequest: true,
                isProjectExecutionRequest: false,
                isKnowledgeOnlyQuestion: false,
                isCapabilityCollaborationRequest: true
            )
        )

        XCTAssertTrue(reply.contains("继续推进当前工作内容么"))
    }

    func testExecutionCoordinatorDoesNotDuplicateContinuationQuestion() {
        let coordinator = LingShuExecutionCoordinator()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [.init(agent: "执行", task: "产出代码")]
        )

        let reply = coordinator.postProcessExecutionReply(
            "已给出代码。需要我继续帮你运行验证么？",
            userPrompt: "写一个 web 爬虫",
            route: route,
            context: .init(
                isDevelopmentQueueRequest: true,
                isProjectExecutionRequest: false,
                isKnowledgeOnlyQuestion: false,
                isCapabilityCollaborationRequest: true
            )
        )

        XCTAssertEqual(reply, "已给出代码。需要我继续帮你运行验证么？")
    }

    func testIntentClarificationPolicyStopsVagueActionBeforeRouting() {
        let policy = LingShuIntentClarificationPolicy()
        let decision = policy.clarification(
            for: "帮我优化一下",
            memoryContext: .init(hotMatches: [], coldMatches: [], shouldLoadHistory: false, status: "无记忆")
        )

        XCTAssertNotNil(decision)
        XCTAssertTrue(decision?.question.contains("确认") == true)
        XCTAssertTrue(decision?.reason.contains("缺少对象") == true || decision?.reason.contains("交付口径") == true)
    }

    func testIntentClarificationPolicyAllowsConcreteDevelopmentTask() {
        let policy = LingShuIntentClarificationPolicy()
        let decision = policy.clarification(
            for: "写一个简单的 web 爬虫",
            memoryContext: .init(hotMatches: [], coldMatches: [], shouldLoadHistory: false, status: "无记忆")
        )

        XCTAssertNil(decision)
    }

    func testIntentClarificationPolicyAsksForUnderspecifiedPPT() {
        let policy = LingShuIntentClarificationPolicy()
        let decision = policy.clarification(
            for: "做个 PPT",
            memoryContext: .init(hotMatches: [], coldMatches: [], shouldLoadHistory: false, status: "无记忆")
        )

        XCTAssertNotNil(decision)
        XCTAssertTrue(decision?.question.contains("主题") == true)
        XCTAssertTrue(decision?.question.contains("格式") == true)
    }

    func testIntentClarificationPolicyCombinesClarifiedPrompt() {
        let policy = LingShuIntentClarificationPolicy()
        let clarified = policy.clarifiedPrompt(
            originalPrompt: "帮我优化一下",
            clarificationAnswer: "优化灵枢的权限配置页，重点是完整权限和沙箱权限的展示。"
        )

        XCTAssertTrue(clarified.contains("原始需求"))
        XCTAssertTrue(clarified.contains("用户补充说明"))
        XCTAssertTrue(clarified.contains("权限配置页"))
    }

    func testTaskRuntimeCoordinatorBeginsRestoredThreadInMemoryStage() {
        let coordinator = LingShuTaskRuntimeCoordinator()

        let runtime = coordinator.begin(
            taskID: "task-1",
            memoryStatus: "命中历史线程",
            engineLabel: "OpenAI / gpt",
            restored: true
        )

        XCTAssertEqual(runtime.stage, .memory)
        XCTAssertEqual(runtime.executionEngine, "OpenAI / gpt")
        XCTAssertEqual(runtime.checks.first(where: { $0.title == "记忆" })?.state, .done)
    }

    func testTaskRuntimeCoordinatorRoutesAgentTaskIntoPermissionStage() {
        let coordinator = LingShuTaskRuntimeCoordinator()
        let route = CodexRoutePayload(
            needsAgents: true,
            agents: [.init(agent: "执行", task: "产出代码")],
            summary: "需要执行"
        )
        let initial = coordinator.begin(
            taskID: "task-2",
            memoryStatus: "未命中执行记忆",
            engineLabel: "Codex / gpt",
            restored: false
        )

        let runtime = coordinator.afterRoute(
            initial,
            route: route,
            engineLabel: "Codex / gpt",
            permissionBoundary: "sandbox"
        )

        XCTAssertEqual(runtime.stage, .permission)
        XCTAssertEqual(runtime.permissionBoundary, "sandbox")
        XCTAssertEqual(runtime.checks.first(where: { $0.title == "权限" })?.state, .running)
    }

    func testTaskRuntimeCoordinatorExecutesMonitorsAndDelivers() {
        let coordinator = LingShuTaskRuntimeCoordinator()
        let initial = coordinator.begin(
            taskID: "task-3",
            memoryStatus: "未命中执行记忆",
            engineLabel: "Codex / gpt",
            restored: false
        )

        let executing = coordinator.executing(initial, permissionBoundary: "sandbox")
        let monitoring = coordinator.monitoring(executing)
        let delivered = coordinator.delivered(monitoring)

        XCTAssertEqual(executing.stage, .executing)
        XCTAssertEqual(monitoring.stage, .monitoring)
        XCTAssertEqual(delivered.stage, .delivering)
        XCTAssertEqual(delivered.reviewGate, "已通过本轮验收")
        XCTAssertEqual(delivered.checks.first(where: { $0.title == "Review" })?.state, .done)
    }

    func testMemoryServicePreparesMainThreadMemoryFromHotRecord() {
        let suiteName = "LingShuMemoryServiceTests.hot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let repository = LingShuMemoryRepository(defaults: defaults)
        let service = LingShuMemoryService(repository: repository)
        let now = Date()
        repository.saveMainThreadRecords([
            .init(
                id: "main-hot-1",
                title: "灵枢机制：主线程记忆",
                summary: "主线程负责检索记忆、判断任务是否需要能力协作。",
                lastPrompt: "灵枢主线程记忆怎么设计",
                category: "灵枢机制",
                tags: ["灵枢", "记忆", "线程"],
                messageCount: 2,
                createdAt: now,
                updatedAt: now,
                compressedAt: nil
            )
        ])

        let prepared = service.prepareMainThreadMemory(for: "继续说一下灵枢的线程记忆")

        XCTAssertTrue(prepared.context.shouldLoadHistory)
        XCTAssertEqual(prepared.context.hotMatches.first?.id, "main-hot-1")
        XCTAssertTrue(prepared.mainMemoryStatus.contains("灵枢机制"))
    }

    func testMemoryServiceRestoresExecutionMemoryByTaskTags() {
        let suiteName = "LingShuMemoryServiceTests.exec.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = LingShuMemoryService(repository: LingShuMemoryRepository(defaults: defaults))

        service.rememberTask(
            prompt: "写一个 web 爬虫",
            status: "delivered",
            summary: "已产出可运行爬虫代码，并建议下一步运行验证。",
            taskID: "task-crawler",
            taskRecordID: "record-crawler"
        )

        let lookup = service.taskMemoryLookup(for: "继续优化 web 爬虫")

        XCTAssertEqual(lookup.hotMatch?.id, "task-crawler")
        XCTAssertEqual(lookup.hotMatch?.executionRecordID, "record-crawler")
        XCTAssertTrue(lookup.restored)
        XCTAssertTrue(lookup.memoryStatus.contains("续接"))
    }

    func testRealtimePerceptionProviderBuildsGenericModelContract() throws {
        let endpoint = LingShuRealtimePerceptionEndpoint(
            id: "vision-model-1",
            displayName: "视觉解析模型",
            endpoint: URL(string: "https://model.example.test/perception/events")!,
            apiKey: "test-key",
            protocolName: "lingshu-realtime-json",
            supportedSignals: [.audioTranscript, .videoFrame]
        )
        let provider = LingShuHTTPRealtimePerceptionProvider(endpoint: endpoint)
        let envelope = LingShuPerceptionEnvelope(
            timestamp: Date(timeIntervalSince1970: 1_786_000_000),
            kind: .audioTranscript,
            source: "mac.microphone",
            textPayload: "测试语音",
            binaryPayload: nil,
            metadata: ["final": "true"]
        )

        let contract = try provider.makeInvocationContract(for: envelope)
        let body = String(data: contract.body, encoding: .utf8) ?? ""

        XCTAssertEqual(contract.url.absoluteString, "https://model.example.test/perception/events")
        XCTAssertEqual(contract.method, "POST")
        XCTAssertEqual(contract.headers["Authorization"], "Bearer test-key")
        XCTAssertEqual(contract.headers["X-LingShu-Protocol"], "lingshu-realtime-json")
        XCTAssertTrue(body.contains("audioTranscript"))
        XCTAssertTrue(body.contains("测试语音"))
    }

    @MainActor
    func testRealtimePerceptionGatewayRegistersRemoteRoutesWithoutChangingLocalDefault() {
        let gateway = LingShuRealtimePerceptionGateway()
        let endpoint = LingShuRealtimePerceptionEndpoint(
            id: "audio-model-1",
            displayName: "音频解析模型",
            endpoint: URL(string: "https://model.example.test/audio")!,
            apiKey: "",
            protocolName: "lingshu-realtime-json",
            supportedSignals: [.audioChunk, .audioTranscript]
        )

        gateway.configureRemoteEndpoints([endpoint])
        XCTAssertEqual(gateway.activeRoute, .local)
        XCTAssertEqual(gateway.availableRoutes.count, 2)

        gateway.ingestAudioTranscript("灵枢开始监听", isFinal: false)
        XCTAssertEqual(gateway.eventCount, 1)
        XCTAssertTrue(gateway.lastEventSummary.contains("语音转写"))

        gateway.selectRoute(id: "audio-model-1")
        XCTAssertEqual(gateway.activeRoute.displayName, "音频解析模型")
        XCTAssertEqual(gateway.activeRoute.mode, .realtimeModel)
    }

    func testVoiceTranscriptNormalizerCompactsChineseSpacing() {
        let normalized = LingShuVoiceTranscriptNormalizer.normalize(" 灵 枢  帮 我 写 一个 web 爬虫 。 ")

        XCTAssertEqual(normalized, "灵枢帮我写一个 web 爬虫。")
    }

    func testEmbeddedSenseVoiceRuntimeReportsMissingAssets() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-empty-asr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let status = LingShuEmbeddedASRRuntimeLocator.senseVoiceSherpaONNXStatus(
            includeDefaultRoots: false,
            extraSearchRoots: [root]
        )

        XCTAssertFalse(status.isAvailable)
        XCTAssertTrue(status.missingItems.contains("sherpa-onnx microphone runtime"))
        XCTAssertTrue(status.missingItems.contains("SenseVoice model.onnx"))
        XCTAssertTrue(status.missingItems.contains("tokens.txt"))
        XCTAssertTrue(status.missingItems.contains("silero_vad.onnx"))
    }

    func testEmbeddedSenseVoiceRuntimeDetectsReadyLocalBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-ready-asr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try Data().write(to: binDirectory.appendingPathComponent("sherpa-onnx-vad-microphone-offline-asr"))
        try Data().write(to: root.appendingPathComponent("model.int8.onnx"))
        try Data().write(to: root.appendingPathComponent("tokens.txt"))
        try Data().write(to: root.appendingPathComponent("silero_vad.onnx"))

        let status = LingShuEmbeddedASRRuntimeLocator.senseVoiceSherpaONNXStatus(
            includeDefaultRoots: false,
            extraSearchRoots: [root]
        )

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.selectedRootPath, root.path)
        XCTAssertTrue(status.activationNote.contains("已就绪"))
    }

    func testSpeechOutputContractBuildsPersonaAwareIndexTTS2Request() throws {
        let request = LingShuSpeechOutputServiceContract.request(
            text: "我是灵枢，有什么可以帮你的？",
            provider: .indexTTS2Service,
            persona: .softDominantMale
        )

        XCTAssertEqual(request.provider, LingShuSpeechOutputProviderKind.indexTTS2Service.rawValue)
        XCTAssertEqual(request.voiceID, "lingshu_soft_dominant_male")
        XCTAssertEqual(request.speakerID, 119)
        XCTAssertTrue(request.personaPrompt.contains("年轻男性"))
        XCTAssertTrue(request.emotionPrompt.contains("笃定"))
        XCTAssertEqual(request.locale, "zh-CN")
    }

    func testSpeechOutputRecommendedProvidersPreferCloudGatewayAndHideLocalVoices() {
        let providers = LingShuSpeechOutputProviderDescriptor.recommendedProviders

        XCTAssertEqual(providers.first?.kind, .customHTTPService)
        XCTAssertFalse(providers.contains(where: { $0.kind == .appleSpeech }))
        XCTAssertFalse(providers.contains(where: { $0.kind == .embeddedSherpaONNXTTS }))
        XCTAssertFalse(providers.contains(where: { $0.kind == .indexTTS2Service }))
    }

    func testEmbeddedTTSRuntimeDetectsReadyLocalBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-ready-tts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeDirectory = root.appendingPathComponent("sherpa-onnx-v1.13.2-osx-arm64-shared/bin", isDirectory: true)
        let modelDirectory = root.appendingPathComponent("vits-icefall-zh-aishell3", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data().write(to: runtimeDirectory.appendingPathComponent("sherpa-onnx-offline-tts"))
        try Data().write(to: modelDirectory.appendingPathComponent("model.onnx"))
        try Data().write(to: modelDirectory.appendingPathComponent("tokens.txt"))
        try Data().write(to: modelDirectory.appendingPathComponent("lexicon.txt"))

        let status = LingShuEmbeddedTTSRuntimeLocator.sherpaONNXTTSStatus(
            includeDefaultRoots: false,
            extraSearchRoots: [root]
        )

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.selectedRootPath, root.path)
        XCTAssertTrue(status.activationNote.contains("已就绪"))
    }

    func testEmbeddedTTSProcessArgumentsUsePersonaSpeakerAndOutputPath() throws {
        let outputURL = URL(fileURLWithPath: "/tmp/lingshu-test.wav")
        let status = LingShuEmbeddedTTSRuntimeStatus(
            providerID: LingShuEmbeddedTTSRuntimeLocator.sherpaTTSProviderID,
            displayName: "本地中文男声",
            isAvailable: true,
            selectedRootPath: "/tmp/tts",
            runtimePath: "/tmp/tts/bin/sherpa-onnx-offline-tts",
            modelPath: "/tmp/tts/vits/model.onnx",
            tokensPath: "/tmp/tts/vits/tokens.txt",
            lexiconPath: "/tmp/tts/vits/lexicon.txt",
            dictDirPath: nil,
            missingItems: [],
            searchPaths: ["/tmp/tts"],
            installHint: ""
        )

        let arguments = try LingShuEmbeddedTTSRuntimeLocator.processArguments(
            status: status,
            text: "我是灵枢。",
            persona: .softDominantMale,
            outputURL: outputURL
        )

        XCTAssertTrue(arguments.contains("--sid=119"))
        XCTAssertTrue(arguments.contains("--output-filename=/tmp/lingshu-test.wav"))
        XCTAssertTrue(arguments.contains("--vits-lexicon=/tmp/tts/vits/lexicon.txt"))
        XCTAssertEqual(arguments.last, "我是灵枢。")
    }

    func testGeneratedTTSAudioIsRemovedAfterMemoryRead() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-tts-cleanup-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
        let audioData = Data("temporary audio".utf8)
        try audioData.write(to: outputURL)

        let loadedData = try VoiceIOManager.readGeneratedAudioAndRemoveFile(at: outputURL)

        XCTAssertEqual(loadedData, audioData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testOwnerIdentityServiceEnrollsAndLocksWithFaceAndVoiceSamples() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-owner-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = LingShuOwnerIdentityService(storageDirectory: root)
        _ = service.beginEnrollment(ownerName: "赵洋", now: Date(timeIntervalSince1970: 1_800_000_000))

        for index in 0..<3 {
            _ = service.ingestVisionObservation(makeOwnerVisionObservation(index: index), now: Date(timeIntervalSince1970: 1_800_000_010 + Double(index)))
            _ = service.ingestAudioPacket(makeOwnerAudioPacket(amplitude: 4_000 + index * 200), now: Date(timeIntervalSince1970: 1_800_000_020 + Double(index)))
        }

        _ = service.ingestVisionObservation(makeOwnerVisionObservation(index: 1), now: Date(timeIntervalSince1970: 1_800_000_040))
        let snapshot = service.ingestAudioPacket(makeOwnerAudioPacket(amplitude: 4_200), now: Date(timeIntervalSince1970: 1_800_000_041))

        XCTAssertEqual(snapshot.enrollmentState, .enrolled)
        XCTAssertEqual(snapshot.ownerName, "赵洋")
        XCTAssertTrue(snapshot.lockEnabled)
        XCTAssertTrue(snapshot.isLocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.profileFileURL.path))
    }

    func testOwnerIdentityServiceRequiresBothFaceAndVoiceForLock() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-owner-identity-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = LingShuOwnerIdentityService(storageDirectory: root)
        _ = service.beginEnrollment(ownerName: "主人")
        for index in 0..<3 {
            _ = service.ingestVisionObservation(makeOwnerVisionObservation(index: index))
            _ = service.ingestAudioPacket(makeOwnerAudioPacket(amplitude: 5_000 + index * 100))
        }

        let reloaded = LingShuOwnerIdentityService(storageDirectory: root)
        let voiceOnly = reloaded.ingestAudioPacket(makeOwnerAudioPacket(amplitude: 5_100))

        XCTAssertEqual(voiceOnly.enrollmentState, .enrolled)
        XCTAssertTrue(voiceOnly.lockEnabled)
        XCTAssertFalse(voiceOnly.isLocked)

        let secondReload = LingShuOwnerIdentityService(storageDirectory: root)
        let faceOnly = secondReload.ingestVisionObservation(makeOwnerVisionObservation(index: 1))

        XCTAssertEqual(faceOnly.enrollmentState, .enrolled)
        XCTAssertTrue(faceOnly.lockEnabled)
        XCTAssertFalse(faceOnly.isLocked)
    }

    func testSpeechOutputContractKeepsCloudVoiceAsEndpointAdapter() throws {
        let urlRequest = try LingShuSpeechOutputServiceContract.makeURLRequest(
            endpoint: "https://example.com/lingshu/tts",
            provider: .doubaoService,
            persona: .softDominantMale,
            text: "收到，我来处理。",
            apiKey: "secret"
        )

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNotNil(urlRequest.httpBody)
    }

    func testEngineeringArtifactServiceCreatesRunnableCrawlerArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-artifact-crawler-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let service = LingShuEngineeringArtifactService()
        let artifacts = service.materializeArtifacts(
            prompt: "写一个简单的 web 爬虫",
            reply: "已生成可运行代码。",
            workingDirectory: root.path,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let crawler = try XCTUnwrap(artifacts.first { $0.location.hasSuffix("crawler.py") })
        let crawlerURL = URL(fileURLWithPath: crawler.location)
        let sampleURL = crawlerURL.deletingLastPathComponent().appendingPathComponent("sample.html")
        let outputURL = crawlerURL.deletingLastPathComponent().appendingPathComponent("run_result.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: crawlerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleURL.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [crawlerURL.path, sampleURL.absoluteString, "--limit", "5", "--output", outputURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let payload = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(payload.contains("LingShu crawler sample"))
        XCTAssertTrue(payload.contains("https://example.com/demo"))
    }

    func testEngineeringArtifactServiceCreatesPresentationArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-artifact-ppt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let service = LingShuEngineeringArtifactService()
        let artifacts = service.materializeArtifacts(
            prompt: "给我做一个介绍灵枢的 PPT",
            reply: "灵枢是对话式 AI 中枢。",
            workingDirectory: root.path,
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let html = try XCTUnwrap(artifacts.first { $0.location.hasSuffix("lingshu-presentation.html") })
        let pptx = try XCTUnwrap(artifacts.first { $0.location.hasSuffix("lingshu-presentation.pptx") })
        let manifest = try XCTUnwrap(artifacts.first { $0.location.contains("artifact-manifest") })

        XCTAssertTrue(FileManager.default.fileExists(atPath: html.location))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pptx.location))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.location))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", pptx.location]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeOwnerVisionObservation(index: Int) -> LingShuVisionObservation {
        LingShuVisionObservation(
            timestamp: Date(timeIntervalSince1970: 1_800_000_100 + Double(index)),
            summary: "检测到 1 张人脸",
            faceCount: 1,
            recognizedText: String(repeating: "灵枢", count: index + 1),
            brightness: 0.42 + Double(index) * 0.04,
            motion: 0.08 + Double(index) * 0.02,
            faceSignature: makeOwnerFaceSignature(offset: Double(index) * 0.006),
            frameWidth: 1280,
            frameHeight: 720
        )
    }

    private func makeOwnerFaceSignature(offset: Double) -> [Double] {
        [
            0.34, 0.42, 0.50, 0.56,
            0.21, 0.70, 0.33, 0.72,
            0.66, 0.72, 0.78, 0.70,
            0.48, 0.50, 0.50, 0.42,
            0.42, 0.28, 0.58, 0.28,
            0.42, 0.18, 0.58, 0.18
        ].map { $0 + offset }
    }

    private func makeOwnerAudioPacket(amplitude: Int) -> LingShuAudioStreamPacket {
        var data = Data()
        data.reserveCapacity(1024 * 2)

        for index in 0..<1024 {
            let sign = index.isMultiple(of: 2) ? 1 : -1
            let wobble = (index % 13) * 9
            let value = Int16(max(min(sign * (amplitude + wobble), Int(Int16.max)), Int(Int16.min)))
            let raw = UInt16(bitPattern: value)
            data.append(UInt8(raw & 0xff))
            data.append(UInt8((raw >> 8) & 0xff))
        }

        return LingShuAudioStreamPacket(
            timestamp: Date(),
            pcm16Data: data,
            sampleRate: 16_000,
            channelCount: 1,
            frameCount: 1024
        )
    }
}
