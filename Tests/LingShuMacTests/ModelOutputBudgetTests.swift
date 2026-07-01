import XCTest
@testable import LingShuMac

/// 动态输出预算:大输入自动调小输出(防撑爆上下文)、小输入给到模型硬上限、未知模型保守、绝不超上限被 400。
final class ModelOutputBudgetTests: XCTestCase {

    func testSmallInputGetsModelOutputCap() {
        // 输入很小 → 给满该模型的输出硬上限(不浪费、不截断)。
        let claude = LingShuModelOutputBudget.dynamicMaxTokens(model: "claude-sonnet-4-6", estimatedInputChars: 2_000)
        XCTAssertEqual(claude, LingShuModelOutputBudget.maxOutputCap(model: "claude-sonnet-4-6"))
        XCTAssertEqual(claude, 32_000, "Claude 小输入应给到 32K 输出上限")
    }

    func testNeverExceedsModelOutputCap() {
        // 即便上下文还很空,也绝不超过该模型单次输出硬上限(否则网关 400 砸整条请求)。
        for model in ["claude-opus-4.1", "deepseek-chat", "MiniMax-M3", "glm-4.6", "qwen2.5", "openai/gpt-5"] {
            let budget = LingShuModelOutputBudget.dynamicMaxTokens(model: model, estimatedInputChars: 1_000)
            XCTAssertLessThanOrEqual(budget, LingShuModelOutputBudget.maxOutputCap(model: model), "\(model) 不得超输出硬上限")
        }
    }

    func testLargeInputShrinksOutputToFitContext() {
        // 输入快撑满上下文 → 输出预算自动调小,保证 输入+输出 不超上下文窗口。
        let ctx = LingShuModelOutputBudget.contextWindow(model: "deepseek-chat")   // 128K
        let bigChars = (ctx - 4_000) * 3   // 估算 token ≈ chars/3,逼近上下文上限
        let budget = LingShuModelOutputBudget.dynamicMaxTokens(model: "deepseek-chat", estimatedInputChars: bigChars)
        XCTAssertLessThan(budget, LingShuModelOutputBudget.maxOutputCap(model: "deepseek-chat"), "大输入应把输出调小到上限以下")
        let inputTokens = LingShuModelOutputBudget.estimateTokens(chars: bigChars)
        XCTAssertLessThanOrEqual(inputTokens + budget, ctx, "输入+输出不得超过上下文窗口")
    }

    func testFloorWhenInputOverflowsContext() {
        // 输入已超上下文 → 仍给一个正的下限(1024),不返回 0/负数。
        let budget = LingShuModelOutputBudget.dynamicMaxTokens(model: "claude-sonnet-4-6", estimatedInputChars: 10_000_000)
        XCTAssertEqual(budget, 1_024, "输入溢出也要兜一个正的下限")
    }

    func testUnknownModelIsConservative() {
        // 未知模型:输出上限保守(绝不 400),但仍 ≥ 下限。
        let budget = LingShuModelOutputBudget.dynamicMaxTokens(model: "some-brand-new-llm-x9", estimatedInputChars: 3_000)
        XCTAssertEqual(budget, 8_192, "未知模型走保守输出上限")
    }
}
