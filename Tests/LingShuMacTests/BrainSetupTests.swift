import XCTest
@testable import LingShuMac

final class BrainSetupTests: XCTestCase {
    func testOpenAIPresetNeedsOnlyTokenAndUsesCatalogEndpoint() throws {
        let configuration = try LingShuBrainSetupConfiguration.make(
            route: .openAI,
            token: "test-token",
            selectedModel: "",
            customEndpoint: "",
            customModel: ""
        )

        XCTAssertEqual(configuration.providerID, "openai")
        XCTAssertEqual(configuration.providerName, "OpenAI")
        XCTAssertEqual(configuration.endpoint, "https://api.openai.com/v1")
        XCTAssertFalse(configuration.model.isEmpty)
        XCTAssertEqual(configuration.apiKey, "test-token")
    }

    func testClaudePresetDefaultsToSonnet() throws {
        let configuration = try LingShuBrainSetupConfiguration.make(
            route: .claude,
            token: "test-token",
            selectedModel: "",
            customEndpoint: "ignored",
            customModel: "ignored"
        )

        XCTAssertEqual(configuration.providerID, "anthropic")
        XCTAssertTrue(configuration.model.localizedCaseInsensitiveContains("sonnet"))
        XCTAssertEqual(configuration.endpoint, "https://api.anthropic.com/v1")
    }

    func testDeepSeekPresetNeedsOnlyToken() throws {
        let configuration = try LingShuBrainSetupConfiguration.make(
            route: .deepSeek,
            token: "test-token",
            selectedModel: "",
            customEndpoint: "",
            customModel: ""
        )

        XCTAssertEqual(configuration.providerID, "deepseek")
        XCTAssertEqual(configuration.endpoint, "https://api.deepseek.com")
        XCTAssertEqual(configuration.model, "deepseek-chat")
    }

    func testMiniMaxPresetDefaultsToM3() throws {
        let configuration = try LingShuBrainSetupConfiguration.make(
            route: .minimax,
            token: "test-token",
            selectedModel: "",
            customEndpoint: "",
            customModel: ""
        )

        XCTAssertEqual(configuration.providerID, "minimax-official")
        XCTAssertEqual(configuration.endpoint, "https://api.minimaxi.com/v1")
        XCTAssertEqual(configuration.model, "MiniMax-M3")
    }

    func testCustomProviderRequiresARealEndpointAndModel() {
        XCTAssertThrowsError(try LingShuBrainSetupConfiguration.make(
            route: .custom,
            token: "test-token",
            selectedModel: "",
            customEndpoint: "not-a-url",
            customModel: "custom-model"
        )) { error in
            XCTAssertEqual(error as? LingShuBrainSetupInputError, .invalidEndpoint)
        }

        XCTAssertThrowsError(try LingShuBrainSetupConfiguration.make(
            route: .custom,
            token: "test-token",
            selectedModel: "",
            customEndpoint: "https://example.com/v1",
            customModel: ""
        )) { error in
            XCTAssertEqual(error as? LingShuBrainSetupInputError, .missingModel)
        }
    }
}
