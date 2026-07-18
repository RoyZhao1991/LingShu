import XCTest
@testable import LingShuMac

final class LiveBrainSetupTests: XCTestCase {
    func testDeepSeekOfficialPresetWhenExplicitlyEnabled() async throws {
        guard let token = ProcessInfo.processInfo.environment["LINGSHU_LIVE_DEEPSEEK_TOKEN"],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set LINGSHU_LIVE_DEEPSEEK_TOKEN to run the live provider probe.")
        }

        let configuration = try LingShuBrainSetupConfiguration.make(
            route: .deepSeek,
            token: token,
            selectedModel: "",
            customEndpoint: "",
            customModel: ""
        )
        let model = LingShuGatewayAgentModel(
            client: LingShuRemoteModelClient(),
            provider: configuration.providerName,
            model: configuration.model,
            endpoint: configuration.endpoint,
            protocolName: configuration.protocolName,
            apiKey: configuration.apiKey,
            temperature: 0,
            timeout: 20,
            maxAttempts: 1
        )

        let response = await model.respond(
            messages: [.init(role: .user, content: "Reply only: OK")],
            tools: []
        )
        switch response {
        case .text(let text):
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .toolCalls:
            XCTFail("The connection probe unexpectedly requested a tool call.")
        case .failed:
            XCTFail("The connection probe failed.")
        }
    }
}
