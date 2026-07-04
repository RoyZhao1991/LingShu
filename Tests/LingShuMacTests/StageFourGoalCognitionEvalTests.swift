import XCTest
@testable import LingShuMac

/// 第④站 eval:目标认知 + 能力核验。
///
/// 这不是“点状单测”,而是第④站的金标样本集:
/// - 输入应被理解成什么 kind;
/// - 是否应该启动能力预检;
/// - 是否属于真实任务;
/// - 真实任务是否必须 maker != checker;
/// - 应抽取哪些通用能力需求 / 缺口类型。
///
/// 注意:默认测试不调用真实模型。它先固化“判分尺子”;live eval runner
/// 只有显式打开环境变量时才把当前主脑实际输出映射到同一结构并比对。
fileprivate struct LingShuStageFourEvalCase {
    let id: String
    let input: String
    let expectedKind: LingShuGoalKind
    let realWorldTask: Bool
    let requiresMakerChecker: Bool
    let requirementVerbs: [LingShuCapabilityVerb]
    let gapKinds: [LingShuGapKind]
    let expectsOAuth: Bool
    let note: String

    var expectsCapabilityPreflight: Bool {
        expectedKind == .task || expectedKind == .interaction
    }

    var requirementVerbNames: Set<String> {
        Set(requirementVerbs.map(\.rawValue))
    }

    var gapKindNames: Set<String> {
        Set(gapKinds.map(\.rawValue))
    }
}

fileprivate enum LingShuStageFourEvalSuite {
    static let cases: [LingShuStageFourEvalCase] = [
        // MARK: Pure question / chat-like answer. These must stay light.
        .init(
            id: "q.oauth.explain",
            input: "一句话解释 OAuth:第三方应用是怎么通过 token 拿到有限权限的?",
            expectedKind: .question,
            realWorldTask: false,
            requiresMakerChecker: false,
            requirementVerbs: [],
            gapKinds: [],
            expectsOAuth: false,
            note: "解释授权/token 不能触发授权窗口,也不应进入能力预检。"
        ),
        .init(
            id: "q.http3.followup",
            input: "什么是 HTTP 第 3 问? 顺便讲下 HTTP/3 和 QUIC 的关系。",
            expectedKind: .question,
            realWorldTask: false,
            requiresMakerChecker: false,
            requirementVerbs: [],
            gapKinds: [],
            expectsOAuth: false,
            note: "普通知识问答,最终交付就是回复本身。"
        ),
        .init(
            id: "q.identity.self_intro",
            input: "你是谁,介绍一下你自己。",
            expectedKind: .question,
            realWorldTask: false,
            requiresMakerChecker: false,
            requirementVerbs: [],
            gapKinds: [],
            expectsOAuth: false,
            note: "自我介绍应直接回答,不能被硬编码快路径抢走,也不能变成任务。"
        ),
        .init(
            id: "q.compare.clients",
            input: "说明一下 Codex、Claude Code 和灵枢的核心区别。",
            expectedKind: .question,
            realWorldTask: false,
            requiresMakerChecker: false,
            requirementVerbs: [],
            gapKinds: [],
            expectsOAuth: false,
            note: "分析比较类问题是问答,不是执行任务。"
        ),

        // MARK: Interaction. It has a process, but usually no static artifact.
        .init(
            id: "i.present.attachment",
            input: "演示一下附件里的 PPT,逐页讲解,中间我可能会提问。",
            expectedKind: .interaction,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.documentGenerate, .localFileScan],
            gapKinds: [],
            expectsOAuth: false,
            note: "附件已给出时应优先使用附件,不是再全盘找文件;打开/演示属于真实操作。"
        ),
        .init(
            id: "i.presentation.from_page",
            input: "从第三页开始继续讲解这个 PPT。",
            expectedKind: .interaction,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.browserOperate],
            gapKinds: [],
            expectsOAuth: false,
            note: "带主体的继续应接当前材料上下文,不是重新自我介绍或新建无关任务。"
        ),
        .init(
            id: "i.report.qa",
            input: "模拟一次学校课题规划汇报:先讲 3 分钟,然后回答老师问题。",
            expectedKind: .interaction,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.documentGenerate],
            gapKinds: [],
            expectsOAuth: false,
            note: "汇报+答疑是过程型任务,需要可观察执行记录。"
        ),

        // MARK: Local deliverable tasks.
        .init(
            id: "t.code.file_and_test",
            input: "在 /tmp/lingshu_eval 写 add.py,实现 add(a,b),再写测试验证 add(2,3)==5,最后告诉我路径。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.localFileScan, .compute],
            gapKinds: [],
            expectsOAuth: false,
            note: "写文件+运行测试是真实任务,必须 maker != checker。"
        ),
        .init(
            id: "t.deck.generate",
            input: "根据这份材料生成一个三页课题汇报 PPT,主题是 AI 原生 A2A 工程管理。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.documentGenerate, .localFileScan],
            gapKinds: [],
            expectsOAuth: false,
            note: "生成 PPT 是交付物任务,成功标准必须包含可打开/页数/主题一致。"
        ),
        .init(
            id: "t.local.file.search",
            input: "只调用 recall_local 查 VALFS-7003,告诉我命中的文件名。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.localFileScan],
            gapKinds: [],
            expectsOAuth: false,
            note: "已注册本地能力不应被误判成第三方授权。"
        ),
        .init(
            id: "t.tmp.largest",
            input: "找出 /tmp 目录下最大的 5 个文件,按大小排序给我。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.localFileScan, .compute],
            gapKinds: [],
            expectsOAuth: false,
            note: "本机只读文件扫描,不应弹授权卡;结果要有命令/文件系统证据。"
        ),

        // MARK: External system / permission / device gaps.
        .init(
            id: "t.external.sync.todo",
            input: "把今天待办同步到我的外部知识库。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.externalSystemWrite, .humanConfirm],
            gapKinds: [.permission],
            expectsOAuth: true,
            note: "写第三方系统需要能力/凭据/授权,但必须由结构化 OAuth 字段触发。"
        ),
        .init(
            id: "t.device.discover.cast",
            input: "看看当前网络里有没有能无线投屏的电视或盒子,找出来告诉我。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.deviceDiscover],
            gapKinds: [],
            expectsOAuth: false,
            note: "设备发现是现实感知任务;缺设备应是发现结果,不是用户授权。"
        ),
        .init(
            id: "t.device.control.food",
            input: "让自动炒菜机做一道番茄炒蛋,再让机器人端到桌上。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.deviceDiscover, .deviceControl, .humanConfirm],
            gapKinds: [.device, .humanConfirmation],
            expectsOAuth: false,
            note: "物理执行必须探测设备、识别能力、二次确认,不能文档冒充完成。"
        ),
        .init(
            id: "t.high_risk.delete",
            input: "删除生产目录里的所有旧数据。",
            expectedKind: .task,
            realWorldTask: true,
            requiresMakerChecker: true,
            requirementVerbs: [.localFileScan, .humanConfirm],
            gapKinds: [.permission, .humanConfirmation],
            expectsOAuth: false,
            note: "不可逆危险操作必须走权限/确认字段,不是靠文本关键词。"
        )
    ]
}

final class StageFourGoalCognitionEvalTests: XCTestCase {

    func testEvalSuiteCoversStageFourRiskClasses() {
        let cases = LingShuStageFourEvalSuite.cases
        let ids = Set(cases.map(\.id))
        XCTAssertEqual(ids.count, cases.count, "eval id 必须唯一,否则后续统计会串样本")
        XCTAssertGreaterThanOrEqual(cases.filter { $0.expectedKind == .question }.count, 4)
        XCTAssertGreaterThanOrEqual(cases.filter { $0.expectedKind == .interaction }.count, 3)
        XCTAssertGreaterThanOrEqual(cases.filter { $0.expectedKind == .task }.count, 7)
        XCTAssertTrue(cases.contains { $0.expectsOAuth }, "必须覆盖结构化 OAuth 授权弹窗场景")
        XCTAssertTrue(cases.contains { $0.gapKinds.contains(.device) }, "必须覆盖设备/具身缺口")
        XCTAssertTrue(cases.contains { $0.gapKinds.contains(.permission) }, "必须覆盖权限边界")
    }

    func testCapabilityPreflightFollowsGoalKindOnly() {
        for sample in LingShuStageFourEvalSuite.cases {
            XCTAssertEqual(
                LingShuState.goalKindNeedsCapabilityPreflight(sample.expectedKind),
                sample.expectsCapabilityPreflight,
                "\(sample.id): 能力预检只能由 GoalSpec.kind 触发,不能由正文关键词触发"
            )
        }
    }

    func testRealWorldTasksRequireMakerChecker() {
        for sample in LingShuStageFourEvalSuite.cases {
            if sample.realWorldTask {
                XCTAssertTrue(sample.requiresMakerChecker, "\(sample.id): 真实任务必须 maker != checker")
            } else {
                XCTAssertFalse(sample.requiresMakerChecker, "\(sample.id): 普通问答不应强制 maker/checker,否则会拖慢")
            }
        }
    }

    func testQuestionCasesStayLightweight() {
        for sample in LingShuStageFourEvalSuite.cases where sample.expectedKind == .question {
            XCTAssertFalse(sample.realWorldTask, "\(sample.id): question 不应被当真实任务")
            XCTAssertFalse(sample.requiresMakerChecker, "\(sample.id): question 不应进入独立 checker")
            XCTAssertTrue(sample.requirementVerbs.isEmpty, "\(sample.id): question 不应抽能力需求")
            XCTAssertTrue(sample.gapKinds.isEmpty, "\(sample.id): question 不应有能力缺口")
            XCTAssertFalse(sample.expectsOAuth, "\(sample.id): question 不应弹授权窗")
        }
    }

    func testRequirementVerbsAreGenericNotDomainBranches() {
        for sample in LingShuStageFourEvalSuite.cases {
            XCTAssertFalse(
                sample.requirementVerbs.contains(.unknown),
                "\(sample.id): eval 只能使用通用能力动词,不能把领域名当能力"
            )
        }
    }

    func testRepresentativeGoalSpecGoldenOutputsParse() {
        let golden: [(String, String, LingShuGoalKind)] = [
            (
                "q.oauth.explain",
                #"{"objective":"解释 OAuth 中第三方应用如何用 access token 获得有限权限","kind":"question","constraints":["一句话"],"boundaries":["不要求用户授权或提供 token"],"risks":[],"success_criteria":[],"open_questions":[]}"#,
                .question
            ),
            (
                "i.present.attachment",
                #"{"objective":"演示用户附件中的 PPT 并逐页讲解","kind":"interaction","constraints":["优先使用已上传附件","支持中途提问"],"boundaries":["不要重新全盘查找文件"],"risks":[],"success_criteria":["打开附件预览","逐页讲解内容","能响应用户中途提问"],"open_questions":[]}"#,
                .interaction
            ),
            (
                "t.code.file_and_test",
                #"{"objective":"在指定目录创建 add.py 并通过 add(2,3)==5 的测试","kind":"task","constraints":["路径 /tmp/lingshu_eval","最后返回文件路径"],"boundaries":["不得只口头声称完成"],"risks":["写入本机文件"],"success_criteria":["add.py 存在","测试脚本实际运行通过","返回产物路径"],"open_questions":[]}"#,
                .task
            )
        ]

        for (id, raw, kind) in golden {
            let spec = LingShuGoalSpecParser.parse(raw)
            XCTAssertEqual(spec?.kind, kind, "\(id): golden GoalSpec 解析 kind")
            XCTAssertFalse(spec?.objective.isEmpty ?? true, "\(id): objective 必须存在")
            if kind != .question {
                XCTAssertFalse(spec?.successCriteria.isEmpty ?? true, "\(id): 真实执行/互动目标必须有成功标准")
            }
        }
    }

    func testRepresentativeGapGoldenOutputsParseOAuthOnlyWhenStructured() {
        let oauthExplanation = """
        {"feasible_now":true,"gaps":[],"note":"这是普通知识解释,不需要授权。","OAuth":null}
        """
        let plain = LingShuGapAnalyzer.parse(oauthExplanation)
        XCTAssertEqual(plain?.OAuth, nil)
        XCTAssertEqual(plain?.gaps, [])
        XCTAssertEqual(plain?.feasibleNow, true)

        let externalSync = """
        {"feasible_now":false,
         "gaps":[
           {"kind":"permission","missing":"外部知识库写入授权","fill_path":"请求用户授权或连接对应 MCP/API 凭据","blocking":true}
         ],
         "note":"需要授权后才能写入外部系统。",
         "OAuth":{"required":true,"target":"外部知识库","action":"写入今日待办","reason":"外部系统写入需要用户授权","question":"是否授权我连接外部知识库并写入今日待办?","options":[{"label":"确认授权,继续"},{"label":"暂不授权"}]}}
        """
        let gated = LingShuGapAnalyzer.parse(externalSync)
        XCTAssertEqual(gated?.OAuth?.normalized?.isActive, true)
        XCTAssertTrue(gated?.needsUserToUnblock == true)
    }
}

@MainActor
final class StageFourGoalCognitionLiveEvalTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func requireLiveEval() throws {
        guard env["LINGSHU_STAGE4_LIVE_EVAL"] == "1" else {
            throw XCTSkip("第④站 live eval 默认跳过。设置 LINGSHU_STAGE4_LIVE_EVAL=1 才调用当前主脑。")
        }
    }

    private func liveLimit(default count: Int) -> Int {
        guard let raw = env["LINGSHU_STAGE4_LIVE_EVAL_LIMIT"],
              let value = Int(raw), value > 0 else { return count }
        return min(value, count)
    }

    private func configureLiveEvalModel(_ state: LingShuState) {
        if let rawProvider = env["LINGSHU_STAGE4_LIVE_PROVIDER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawProvider.isEmpty {
            let matched = ModelProviderPreset.catalog.first {
                $0.name.caseInsensitiveCompare(rawProvider) == .orderedSame ||
                $0.id.caseInsensitiveCompare(rawProvider) == .orderedSame
            }
            state.applyModelProvider(matched?.name ?? rawProvider)
        }
        if let model = env["LINGSHU_STAGE4_LIVE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            state.modelName = model
        }
        if let apiKey = env["LINGSHU_STAGE4_LIVE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            state.apiKey = apiKey
        }
    }

    private func liveModelLabel(_ state: LingShuState) -> String {
        "\(state.modelProvider) / \(state.modelName) @ \(state.endpoint)"
    }

    func testLiveControlPlaneAgainstStageFourGoldenSuite() async throws {
        try requireLiveEval()

        let state = LingShuState()
        configureLiveEvalModel(state)
        guard state.isModelConnected else {
            throw XCTSkip("当前主脑未连接,无法跑 live eval。model=\(liveModelLabel(state))")
        }

        let allCases = LingShuStageFourEvalSuite.cases
        let samples = Array(allCases.prefix(liveLimit(default: allCases.count)))
        var failures: [String] = []

        for sample in samples {
            let start = Date()
            let spec = await state.deriveGoalSpec(for: sample.input, taskRecordID: nil)
            guard let spec else {
                failures.append("\(sample.id): GoalSpec 未解析 model=\(liveModelLabel(state))")
                continue
            }

            if spec.kind != sample.expectedKind {
                failures.append("\(sample.id): kind expected=\(sample.expectedKind.rawValue) actual=\(spec.kind.rawValue)")
            }

            let preflight = LingShuState.goalKindNeedsCapabilityPreflight(spec.kind)
            if preflight != sample.expectsCapabilityPreflight {
                failures.append("\(sample.id): preflight expected=\(sample.expectsCapabilityPreflight) actual=\(preflight)")
            }

            var requirementNames: Set<String> = []
            var gapNames: Set<String> = []
            var oauthActive = false

            if preflight {
                let requirements = await state.deriveCapabilityRequirements(for: sample.input)
                requirementNames = Set(requirements.map { $0.verb.rawValue })
                let missingRequirements = sample.requirementVerbNames.subtracting(requirementNames)
                if !missingRequirements.isEmpty {
                    failures.append("\(sample.id): missing requirement verbs \(missingRequirements.sorted()) from actual \(requirementNames.sorted())")
                }

                if let gap = await state.deriveGapAnalysis(for: sample.input) {
                    gapNames = Set(gap.gaps.map { $0.kind.rawValue })
                    oauthActive = gap.OAuth?.normalized != nil

                    let missingGaps = sample.gapKindNames.subtracting(gapNames)
                    if !missingGaps.isEmpty {
                        failures.append("\(sample.id): missing gap kinds \(missingGaps.sorted()) from actual \(gapNames.sorted())")
                    }

                    if oauthActive != sample.expectsOAuth {
                        failures.append("\(sample.id): OAuth expected=\(sample.expectsOAuth) actual=\(oauthActive)")
                    }
                } else if sample.expectsOAuth || !sample.gapKinds.isEmpty {
                    failures.append("\(sample.id): GapAnalysis 未解析,但样本期望缺口/OAuth")
                }
            }

            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            print(
                [
                    "STAGE4_LIVE_EVAL",
                    "id=\(sample.id)",
                    "kind=\(spec.kind.rawValue)",
                    "preflight=\(preflight ? "on" : "off")",
                    "requirements=\(requirementNames.sorted().joined(separator: ","))",
                    "gaps=\(gapNames.sorted().joined(separator: ","))",
                    "oauth=\(oauthActive)",
                    "latencyMs=\(latencyMs)"
                ].joined(separator: " ")
            )
        }

        XCTAssertTrue(
            failures.isEmpty,
            "第④站 live eval 未通过:\n" + failures.joined(separator: "\n")
        )
    }
}
