import Foundation
import XCTest
@testable import LingShuMac

final class SharedKernelRuntimeBridgeTests: XCTestCase {
    @MainActor
    func testMacShellLoadsAndTalksToCanonicalRuntimeKernel() async throws {
        try Self.ensureRuntimeLibraryBuilt()

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
                    executionPermissionMode: .fullAccess,
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
            XCTAssertEqual(snapshot.settings.executionPermissionMode, .fullAccess)
            XCTAssertFalse(snapshot.providerConfigured)
            XCTAssertEqual(snapshot.queuedTaskCount, 0)
        } catch {
            await runtime.stop()
            throw error
        }
        await runtime.stop()
    }

    private static func ensureRuntimeLibraryBuilt() throws {
        let source = URL(fileURLWithPath: #filePath)
        let repository = source
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = repository.appendingPathComponent("Runtime/Grok/Cargo.toml")
        let library = repository.appendingPathComponent(
            "Runtime/Grok/target/debug/liblingshu_grok_runtime.dylib"
        )
        guard !FileManager.default.fileExists(atPath: library.path) else { return }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "cargo", "build",
            "--manifest-path", manifest.path,
            "-p", "lingshu-grok-runtime",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: library.path) else {
            let detail = String(data: data, encoding: .utf8) ?? "cargo build produced no readable output"
            throw NSError(
                domain: "SharedKernelRuntimeBridgeTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to build shared runtime library:\n\(detail)"]
            )
        }
    }
}
