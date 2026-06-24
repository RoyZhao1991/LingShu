import XCTest
@testable import LingShuMac

/// 通用中枢 P2·GapAnalyzer 容错解析 + 消费助手守卫(纯逻辑,无模型)。
final class GapAnalysisTests: XCTestCase {

    func testParseFeasibleNoGaps() {
        let a = LingShuGapAnalyzer.parse(#"{"feasible_now":true,"gaps":[],"note":"用 write_file 直接做"}"#)
        XCTAssertEqual(a?.feasibleNow, true)
        XCTAssertEqual(a?.gaps, [])
        XCTAssertFalse(a?.hasBlockingGap ?? true)
    }

    func testParseGapsWithKindsAndBlocking() {
        let raw = """
        ```json
        {"feasible_now":false,"note":"先接 Spotify 再做",
         "gaps":[
           {"kind":"tool","missing":"Spotify 控制工具","fill_path":"用 author_component 据 Spotify Web API 文档自写","blocking":false},
           {"kind":"human_confirmation","missing":"Spotify 账号授权","fill_path":"请你在密码管理器里授权","blocking":true}
         ]}
        ```
        """
        let a = LingShuGapAnalyzer.parse(raw)
        XCTAssertEqual(a?.feasibleNow, false)
        XCTAssertEqual(a?.gaps.count, 2)
        XCTAssertEqual(a?.gaps.first?.kind, .tool)
        XCTAssertEqual(a?.gaps.first?.blocking, false)
        XCTAssertEqual(a?.gaps.last?.kind, .humanConfirmation, "human_confirmation 应映射到 .humanConfirmation")
        XCTAssertTrue(a?.hasBlockingGap ?? false, "有 blocking 缺口")
    }

    func testParseHumanConfirmationCamelCaseToo() {
        let raw = #"{"feasible_now":false,"gaps":[{"kind":"humanConfirmation","missing":"账号授权","fill_path":"ask_user","blocking":true}]}"#
        XCTAssertEqual(LingShuGapAnalyzer.parse(raw)?.gaps.first?.kind, .humanConfirmation)
    }

    func testGapWithoutMissingFiltered() {
        let a = LingShuGapAnalyzer.parse(#"{"feasible_now":true,"gaps":[{"kind":"tool","missing":"  ","fill_path":"x"}]}"#)
        XCTAssertEqual(a?.gaps, [], "missing 空的缺口被过滤")
    }

    func testNoFeasibleFieldIsNil() {
        XCTAssertNil(LingShuGapAnalyzer.parse(#"{"gaps":[]}"#), "缺 feasible_now → 解析失败")
        XCTAssertNil(LingShuGapAnalyzer.parse("不是 JSON"))
        XCTAssertNil(LingShuGapAnalyzer.parse(""))
    }

    func testExecutionGuidanceOnlyInjectsWhenGaps() {
        let feasible = LingShuGapAnalysis(feasibleNow: true, gaps: [], note: "直接做")
        XCTAssertEqual(feasible.executionGuidance(base: "技能提示"), "技能提示", "无缺口→不加压,返回 base 原样")
        let withGap = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .knowledge, missing: "X 领域资料", fillPath: "discover_skill / web_search", blocking: false)
        ], note: "先查资料")
        let g = withGap.executionGuidance(base: "技能提示")
        XCTAssertTrue(g.hasPrefix("技能提示"))
        XCTAssertTrue(g.contains("能力缺口与补齐计划"))
        XCTAssertTrue(g.contains("X 领域资料"))
        XCTAssertTrue(withGap.executionGuidance(base: nil).contains("能力缺口"))
    }

    func testNeedsUserToUnblockAndAskDirective() {
        let needsCred = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation, missing: "账号凭据", fillPath: "请你提供", blocking: true)
        ], note: "")
        XCTAssertTrue(needsCred.needsUserToUnblock)
        XCTAssertTrue(needsCred.executionGuidance(base: nil).contains("ask_user"), "需用户提供的阻断前提→指示先 ask_user 确认")

        let selfFixable = LingShuGapAnalysis(feasibleNow: true, gaps: [
            .init(kind: .tool, missing: "某工具", fillPath: "author_component 自写", blocking: false)
        ], note: "")
        XCTAssertFalse(selfFixable.needsUserToUnblock, "能自补的工具缺口不需要用户")
        XCTAssertFalse(selfFixable.executionGuidance(base: nil).contains("ask_user"), "自补缺口→不加澄清指令")
    }

    func testSummaryReadable() {
        let a = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .device, missing: "舵机", fillPath: "接 ESP32", blocking: true)
        ], note: "需真硬件")
        let s = a.summary
        XCTAssertTrue(s.contains("当前能力不足"))
        XCTAssertTrue(s.contains("缺[device](阻断):舵机"))
        XCTAssertTrue(s.contains("策略:需真硬件"))
    }

    func testRecordPersistsTypedGapAnalysis() throws {
        var rec = LingShuTaskExecutionRecord.create(prompt: "接 Spotify 放歌")
        rec.gapAnalysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .tool, missing: "Spotify 工具", fillPath: "author_component", blocking: false)
        ], note: "自写")
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: data)
        XCTAssertEqual(back.gapAnalysis?.gaps.first?.missing, "Spotify 工具", "缺口分析随记录跨重启持久")
        XCTAssertEqual(back.gapAnalysis?.feasibleNow, false)
    }

    @MainActor
    func testBindGapAnalysisPersistsNoGapAnalysisWithoutTimelineNoise() {
        let state = LingShuState()
        let prompt = "能力足够-\(UUID().uuidString)"
        let recordID = state.createTaskExecutionRecord(for: prompt)
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        let beforeMessages = state.taskExecutionRecords.first { $0.id == recordID }?.messages.count
        let analysis = LingShuGapAnalysis(feasibleNow: true, gaps: [], note: "现有能力可直接完成")

        state.bindGapAnalysis(analysis, to: recordID)
        state.taskExecutionJournal.flush()

        let saved = state.taskExecutionJournal.loadRecords().first { $0.id == recordID }
        XCTAssertEqual(saved?.gapAnalysis, analysis, "无缺口分析也必须作为 typed 字段持久化,不能只留内存")
        let afterMessages = state.taskExecutionRecords.first { $0.id == recordID }?.messages.count
        XCTAssertEqual(afterMessages, beforeMessages, "无缺口不应追加时间线噪声")
    }

    @MainActor
    func testReconcileDropsBogusCredentialGapForVerifiedLocalKnowledgeTools() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation,
                  missing: "index_local_knowledge 工具和 recall_local 工具授权",
                  fillPath: "请用户提供 index_local_knowledge / recall_local 的登录凭据",
                  blocking: true)
        ], note: "模型误以为本机知识工具需要账号授权。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(analysis)

        XCTAssertTrue(reconciled.feasibleNow)
        XCTAssertTrue(reconciled.gaps.isEmpty, "已验证的内置本机知识工具不应被模型臆测成需用户凭据")
        XCTAssertFalse(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testReconcileDropsBogusCredentialGapForAllLocalKnowledgeTools() {
        let state = LingShuState()
        let localTools = [
            "index_local_knowledge",
            "recall_local",
            "index_photos",
            "index_calendar",
            "index_mail",
            "index_browser_history"
        ]
        for tool in localTools {
            let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
                .init(kind: .permission,
                      missing: "\(tool) 工具授权",
                      fillPath: "需要用户提供 \(tool) 的登录凭据后才能调用",
                      blocking: true)
            ], note: "模型误以为本机知识工具需要第三方凭据。")

            let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(analysis)

            XCTAssertTrue(reconciled.feasibleNow, "\(tool) 是已注册本机工具,不应在前置阶段卡成外部授权")
            XCTAssertTrue(reconciled.gaps.isEmpty, "\(tool) 的真实系统权限应由工具执行结果反馈,不是 P2 预阻断")
        }
    }

    @MainActor
    func testReconcileDropsBogusToolGapForBuiltInLocalKnowledgeTools() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .tool,
                  missing: "缺少 index_local_knowledge 和 recall_local 工具",
                  fillPath: "需要用户授权后才能调用 index_local_knowledge 索引目录,再用 recall_local 查询",
                  blocking: true)
        ], note: "模型误把已注册内置工具当成待获取工具。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(analysis)

        XCTAssertTrue(reconciled.feasibleNow)
        XCTAssertTrue(reconciled.gaps.isEmpty)
        XCTAssertFalse(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testReconcileDropsChineseAliasCredentialGapForLocalKnowledgeTools() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "本地知识库索引工具和本地召回工具授权",
                  fillPath: "需要用户给本地知识库索引工具/本地召回工具的登录凭据后才能继续",
                  blocking: true)
        ], note: "模型误把中文能力别名当成外部授权。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(analysis)

        XCTAssertTrue(reconciled.feasibleNow)
        XCTAssertTrue(reconciled.gaps.isEmpty, "中文别名也必须识别为已注册本地能力,不能卡用户授权")
        XCTAssertFalse(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testBindGapAnalysisSanitizesBeforePersisting() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "查询本机 VALFILE-7001")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        let stale = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation,
                  missing: "对本地知识库索引工具授权",
                  fillPath: "请用户提供本地知识库索引工具登录凭据",
                  blocking: true)
        ], note: "旧模型误判。")

        state.bindGapAnalysis(stale, to: recordID)

        let saved = state.taskExecutionRecords.first { $0.id == recordID }?.gapAnalysis
        XCTAssertEqual(saved?.gaps, [], "绑定时就应清洗掉已注册本地能力的假授权缺口")
        XCTAssertEqual(saved?.feasibleNow, true)
    }

    @MainActor
    func testGapAnalysisReadHealsStalePersistedBogusLocalToolGap() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "查询本机 VALFILE-7001")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        let stale = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "需要你给我对「本地知识库索引工具」和「本地召回工具」的授权",
                  fillPath: "登录或提供对应凭据",
                  blocking: true)
        ], note: "旧记录里残留的假阻断。")
        let idx = state.taskExecutionRecords.firstIndex { $0.id == recordID }!
        state.taskExecutionRecords[idx].gapAnalysis = stale
        state.persistTaskExecutionRecords()

        let healed = state.gapAnalysis(for: recordID)

        XCTAssertEqual(healed?.gaps, [], "读取旧记录时也要自愈,否则 UI/完成闸会继续卡在历史假缺口")
        XCTAssertTrue(state.taskExecutionRecords.first { $0.id == recordID }?.gapAnalysis?.gaps.isEmpty == true)
    }

    @MainActor
    func testBogusBuiltInCapabilityHandbackDetectedAtRuntime() {
        let state = LingShuState()
        let question = "需要你给我:对「本地知识库索引工具」的授权;对「本地召回工具」的授权。"

        XCTAssertTrue(state.isBogusBuiltInCapabilityHandback(question))
        XCTAssertTrue(state.builtInCapabilityCorrection(for: question).contains("直接调用对应本地工具"))
    }

    func testResolvedUserGapDoesNotNeedUserAgain() {
        let analysis = LingShuGapAnalysis(feasibleNow: true, gaps: [
            .init(kind: .permission, missing: "第三方 API token", fillPath: "用户已提供", blocking: true, resolved: true)
        ], note: "已解除")

        XCTAssertFalse(analysis.hasBlockingGap)
        XCTAssertFalse(analysis.blockingNeedsUser)
        XCTAssertFalse(analysis.needsUserToUnblock, "resolved=true 的旧缺口不能继续触发 ask_user")
    }

    @MainActor
    func testReconcileKeepsRealExternalCredentialGap() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "external_system.write:用户的第三方工作区",
                  fillPath: "需要用户授权或提供第三方服务凭据",
                  blocking: true)
        ], note: "外部系统写入需要真实授权。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(analysis)

        XCTAssertEqual(reconciled.gaps, analysis.gaps, "外部服务授权缺口必须保留,不能被内置能力复核误删")
        XCTAssertTrue(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testReconcileDropsSpeculativeAuthGapWhenRuntimeToolExplicitlySelected() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "用户的日历服务",
                  fillPath: "需要用户授权或提供日历服务凭据",
                  blocking: true)
        ], note: "模型把已点名的运行时工具误判成外部授权。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(
            analysis,
            contextText: "调用 index_calendar 工具把我的日历索引进本机知识,把结果一句话告诉我。"
        )

        XCTAssertTrue(reconciled.gaps.isEmpty)
        XCTAssertTrue(reconciled.feasibleNow)
        XCTAssertFalse(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testReconcileKeepsUnrelatedExternalGapEvenWhenSomeToolIsNamed() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "用户的第三方工作区",
                  fillPath: "需要用户授权或提供第三方服务凭据",
                  blocking: true)
        ], note: "真实外部授权。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(
            analysis,
            contextText: "先用 run_command 检查本机环境,然后同步到第三方工作区。"
        )

        XCTAssertEqual(reconciled.gaps, analysis.gaps)
        XCTAssertTrue(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testReconcileDropsDeliveryOnlyHumanConfirmationGap() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation,
                  missing: "用户得到最终结果和文件路径的告知",
                  fillPath: "最终回复里告诉用户运行结果和产出物路径",
                  blocking: true)
        ], note: "模型误把交付播报当成用户前提。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(analysis)

        XCTAssertTrue(reconciled.feasibleNow)
        XCTAssertTrue(reconciled.gaps.isEmpty, "交付沟通不能成为 blocking human_confirmation")
        XCTAssertFalse(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testReconcileDropsBareHumanActorPermissionGapForSelfContainedTask() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "用户",
                  fillPath: "需要用户授权或提供凭据后继续",
                  blocking: true)
        ], note: "模型把交互对象误当成权限对象。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(
            analysis,
            contextText: "在目录 /tmp/demo 写 add.py,实现 add(a,b) 返回 a+b,并运行测试验证 add(2,3)==5。"
        )

        XCTAssertTrue(reconciled.feasibleNow)
        XCTAssertTrue(reconciled.gaps.isEmpty, "泛化的「用户授权」不是可执行前提,不能污染自包含本地任务")
        XCTAssertFalse(reconciled.needsUserToUnblock)
    }

    @MainActor
    func testReconcileKeepsRealUserConfirmationGap() {
        let state = LingShuState()
        let analysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation,
                  missing: "用户确认是否允许删除生产数据",
                  fillPath: "删除前必须向用户确认授权",
                  blocking: true)
        ], note: "真实高风险动作必须确认。")

        let reconciled = state.reconcileGapAnalysisWithCapabilityGraph(analysis)

        XCTAssertEqual(reconciled.gaps, analysis.gaps)
        XCTAssertTrue(reconciled.needsUserToUnblock)
    }
}
