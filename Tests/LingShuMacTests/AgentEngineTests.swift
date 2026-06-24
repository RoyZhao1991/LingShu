import XCTest
@testable import LingShuMac

/// 步骤1·agent 引擎抽象的纯逻辑守卫(数据驱动,0 模型依赖)。
final class AgentEngineTests: XCTestCase {

    private func d(_ id: String, _ kind: LingShuAgentEngineKind, _ label: String, _ available: Bool = true)
        -> LingShuAgentEngineDescriptor {
        .init(id: id, kind: kind, providerLabel: label, available: available)
    }

    // MARK: - 来源指纹 / 异源判定

    func testSourceFingerprintNormalizesCaseAndWhitespace() {
        let a = d("a", .localBrain, "DeepSeek")
        let b = d("b", .localBrain, " deepseek ")
        XCTAssertEqual(a.sourceFingerprint, b.sourceFingerprint, "大小写/空白不同的同名 provider 应判同源")
        XCTAssertFalse(LingShuAgentEngineRegistry.areCrossSource(a, b), "同源不应判跨源")
    }

    func testCrossSourceAcrossProvider() {
        let deepseek = d("1", .localBrain, "DeepSeek")
        let minimax = d("2", .localBrain, "MiniMax")
        XCTAssertTrue(LingShuAgentEngineRegistry.areCrossSource(deepseek, minimax), "跨 provider 应判异源")
    }

    func testCrossSourceAcrossKindSameLabel() {
        // 同名但一个是 localBrain 一个是 externalCLI → 不同物种,应判异源。
        let modelClaude = d("m", .localBrain, "Claude")
        let agentClaude = d("a", .externalCLI, "Claude")
        XCTAssertTrue(LingShuAgentEngineRegistry.areCrossSource(modelClaude, agentClaude),
                      "Claude 裸模型 与 Claude Code agent 是不同源")
    }

    // MARK: - 可用池:过滤 + 去重 + 保序

    func testAvailablePoolFiltersUnavailable() {
        let pool = LingShuAgentEngineRegistry.availablePool([
            d("1", .localBrain, "DeepSeek", true),
            d("2", .externalCLI, "Codex", false),       // 未登录 → 滤掉
            d("3", .externalCLI, "Claude Code", false)  // 未接入 → 滤掉
        ])
        XCTAssertEqual(pool.map(\.id), ["1"])
    }

    func testAvailablePoolDedupsByIdPreservingOrder() {
        let pool = LingShuAgentEngineRegistry.availablePool([
            d("localBrain:deepseek", .localBrain, "DeepSeek"),
            d("external:codex", .externalCLI, "Codex"),
            d("localBrain:deepseek", .localBrain, "DeepSeek")  // 当前脑与某档脑重复 → 去重
        ])
        XCTAssertEqual(pool.map(\.id), ["localBrain:deepseek", "external:codex"])
    }

    // MARK: - checker 选择:异源优先 / 同源兜底

    func testPickCheckerPrefersCrossSource() {
        let maker = d("1", .localBrain, "DeepSeek")
        let pool = [maker, d("2", .externalCLI, "Codex"), d("3", .localBrain, "MiniMax")]
        let (checker, cross) = LingShuAgentEngineRegistry.pickChecker(forMaker: maker, from: pool)
        XCTAssertTrue(cross, "有异源候选时应判跨源")
        XCTAssertEqual(checker.id, "2", "异源优先取池中第一个(保序)")
    }

    func testPickCheckerFallsBackToSameSourceWhenNoCrossAvailable() {
        let maker = d("1", .localBrain, "DeepSeek")
        // 池里只有同源(同一个 DeepSeek,不同 id 但同指纹)。
        let pool = [maker, d("1b", .localBrain, "deepseek")]
        let (checker, cross) = LingShuAgentEngineRegistry.pickChecker(forMaker: maker, from: pool)
        XCTAssertFalse(cross, "无异源可用时退化为同源审查")
        XCTAssertEqual(checker.id, maker.id, "同源兜底返回 maker 自身")
    }

    func testPickCheckerSingleEngineDegradesToSelf() {
        let maker = d("1", .localBrain, "DeepSeek")
        let (checker, cross) = LingShuAgentEngineRegistry.pickChecker(forMaker: maker, from: [maker])
        XCTAssertFalse(cross)
        XCTAssertEqual(checker.id, maker.id, "只有一个引擎(self)时 = A2A 地板,同源兜底")
    }
}
