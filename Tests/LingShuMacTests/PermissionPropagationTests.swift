import Foundation
import XCTest
@testable import LingShuMac

final class PermissionPropagationTests: XCTestCase {
    func testFullAccessEnablesGrokAlwaysApproveMode() throws {
        let params = lingShuGrokNewSessionParams(
            workingDirectory: "/tmp/lingshu-permission-test",
            modelID: "grok-test",
            systemPrompt: "Answer in English.",
            role: .maker,
            permissionMode: .fullAccess
        )
        let meta = try encodedMeta(params)

        XCTAssertEqual(meta["yoloMode"] as? Bool, true)
        XCTAssertTrue((meta["rules"] as? String)?.contains("full_access") == true)
        XCTAssertTrue((meta["rules"] as? String)?.contains("Do not ask again") == true)
    }

    func testSandboxKeepsGrokPermissionPromptsEnabled() throws {
        let params = lingShuGrokNewSessionParams(
            workingDirectory: "/tmp/lingshu-permission-test",
            modelID: "grok-test",
            systemPrompt: "Answer in English.",
            role: .maker,
            permissionMode: .sandbox
        )
        let meta = try encodedMeta(params)

        XCTAssertEqual(meta["yoloMode"] as? Bool, false)
        XCTAssertTrue((meta["rules"] as? String)?.contains("Execution permission is sandbox") == true)
        XCTAssertTrue((meta["rules"] as? String)?.contains("explicit user authorization") == true)
    }

    private func encodedMeta(_ params: LingShuGrokNewSessionParams) throws -> [String: Any] {
        let data = try JSONEncoder().encode(params)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(object["_meta"] as? [String: Any])
    }
}
