import XCTest
@testable import LingShuMac

final class SharedKernelRuntimeBridgeTests: XCTestCase {
    @MainActor
    func testMacShellLoadsAndTalksToCanonicalRuntimeKernel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-shared-kernel-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("State", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = LingShuSharedKernelRuntime.shared
        do {
            try await runtime.ensureStarted(dataDirectory: stateDirectory.path)
            let configured = try await runtime.configure(
                settings: LingShuKernelRuntimeSettings(
                    locale: .en,
                    providerId: "bridge-test",
                    providerName: "Bridge Test",
                    protocol: .openAIResponses,
                    endpoint: "http://127.0.0.1:9",
                    model: "mock-agent",
                    workspace: workspace.path,
                    firstRunComplete: true
                ),
                apiKey: nil,
                providerConfigured: false
            )
            let snapshot = try await runtime.snapshot(providerConfigured: false)

            XCTAssertEqual(configured.kernelAbiVersion, LingShuKernelABI.version)
            XCTAssertEqual(snapshot.kernelAbiVersion, LingShuKernelABI.version)
            XCTAssertEqual(snapshot.platform, "macos")
            XCTAssertTrue(snapshot.capabilities.computerControl)
            XCTAssertTrue(snapshot.capabilities.realtimePerception)
            XCTAssertTrue(snapshot.capabilities.internalPreview)
            XCTAssertTrue(snapshot.capabilities.externalOpen)
            XCTAssertEqual(snapshot.settings.providerId, "bridge-test")
            XCTAssertEqual(snapshot.settings.protocol, .openAIResponses)
            XCTAssertEqual(snapshot.settings.workspace, workspace.path)
            XCTAssertFalse(snapshot.providerConfigured)
            XCTAssertEqual(snapshot.queuedTaskCount, 0)
        } catch {
            await runtime.stop()
            throw error
        }
        await runtime.stop()
    }
}
