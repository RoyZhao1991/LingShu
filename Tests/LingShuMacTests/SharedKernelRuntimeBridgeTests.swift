import Foundation
import XCTest
@testable import LingShuMac

final class SharedKernelRuntimeBridgeTests: XCTestCase {
    func testTerminatedRuntimeEventWireValueDecodes() throws {
        let taskID = UUID()
        let payload = """
        {
          "id":"\(UUID().uuidString)",
          "sequence":7,
          "taskId":"\(taskID.uuidString)",
          "parentTaskId":null,
          "kind":"model",
          "state":"cancelled",
          "actor":"LingShu",
          "title":"Writing report",
          "detail":"Three sections were preserved.",
          "createdAt":"2026-08-19T08:00:00Z",
          "updatedAt":"2026-08-19T08:01:00Z"
        }
        """

        let event = try JSONDecoder().decode(
            LingShuKernelRuntimeEvent.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(event.taskId, taskID)
        XCTAssertEqual(event.state, .cancelled)
        XCTAssertEqual(event.detail, "Three sections were preserved.")
    }

    func testToolEventUsesReadableTitleInMainChatAndKeepsRawDetail() {
        let detail = """
        {"title":"基于自学习的标注能力","file_name":"demo.pptx","theme":"midnight","slides":[{"layout":"cover"}]}
        [truncated]
        """
        let event = LingShuKernelRuntimeEvent(
            id: UUID(),
            sequence: 1,
            taskId: UUID(),
            parentTaskId: nil,
            kind: .tool,
            state: .running,
            actor: "LingShu",
            title: "使用 DesignKB 生成演示文稿",
            detail: detail,
            createdAt: "2026-07-29T00:00:00Z",
            updatedAt: "2026-07-29T00:00:00Z"
        )

        XCTAssertEqual(
            LingShuState.sharedKernelUserFacingEventText(event, language: .chinese),
            "使用 DesignKB 生成演示文稿"
        )
        XCTAssertEqual(event.detail, detail, "执行记录必须继续保留完整工具参数")
    }

    func testModelEventKeepsReadableStreamingReply() {
        let event = LingShuKernelRuntimeEvent(
            id: UUID(),
            sequence: 1,
            taskId: UUID(),
            parentTaskId: nil,
            kind: .model,
            state: .running,
            actor: "deepseek-chat",
            title: "模型回合 2",
            detail: "已经完成内容提炼，正在生成演示文稿。",
            createdAt: "2026-07-29T00:00:00Z",
            updatedAt: "2026-07-29T00:00:00Z"
        )

        XCTAssertEqual(
            LingShuState.sharedKernelUserFacingEventText(event, language: .chinese),
            "已经完成内容提炼，正在生成演示文稿。"
        )
    }

    func testEmptyLegacyModelTurnShowsThinkingInsteadOfTurnNumber() {
        let event = LingShuKernelRuntimeEvent(
            id: UUID(),
            sequence: 1,
            taskId: UUID(),
            parentTaskId: nil,
            kind: .model,
            state: .running,
            actor: "deepseek-chat",
            title: "模型回合 4",
            detail: "",
            createdAt: "2026-07-29T00:00:00Z",
            updatedAt: "2026-07-29T00:00:00Z"
        )

        XCTAssertEqual(
            LingShuState.sharedKernelUserFacingEventText(event, language: .chinese),
            "思考中…"
        )
    }

    @MainActor
    func testMacShellLoadsAndTalksToCanonicalRuntimeKernel() async throws {
        try Self.ensureRuntimeLibraryBuilt()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-shared-kernel-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("State", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        let skillDirectory = root.appendingPathComponent("portable-bridge-skill", isDirectory: true)
        let skillManifest = skillDirectory.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: portable-bridge-skill
        description: Verify that the macOS shell reaches the shared external Skill registry.
        ---
        Follow the portable bridge workflow.
        """.write(to: skillManifest, atomically: true, encoding: .utf8)
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
                    loopEngine: .grok,
                    firstRunComplete: true
                ),
                apiKey: nil,
                providerConfigured: false
            )
            let imported = try await runtime.importMemory(
                LingShuKernelMemoryImportPayload(
                    source: "bridge-test",
                    sourceVersion: "v1",
                    entries: [
                        LingShuKernelMemoryImportEntry(
                            id: "bridge-memory",
                            kind: .preference,
                            tier: .hot,
                            title: "Language preference",
                            content: "The user prefers concise English answers.",
                            lastPrompt: "",
                            tags: ["language"],
                            source: .legacySwift,
                            importance: 0.8,
                            confidence: 1,
                            sensitive: false,
                            messageCount: 1,
                            taskId: nil,
                            executionRecordId: nil,
                            createdAt: nil,
                            updatedAt: nil,
                            archivedAt: nil,
                            compressedAt: nil,
                            aliases: []
                        )
                    ]
                )
            )
            let importedSkills = try await runtime.importExternalSkill(path: skillManifest.path)
            let importedSkill = try XCTUnwrap(importedSkills.first)
            let listedSkills = try await runtime.listExternalSkills()
            try """
            ---
            name: portable-bridge-skill
            description: Verify that explicit refresh re-reads the external Skill source.
            disable-model-invocation: true
            ---
            Follow the refreshed portable bridge workflow.
            """.write(to: skillManifest, atomically: true, encoding: .utf8)
            let refreshedSkills = try await runtime.refreshExternalSkills()
            let disabledSkill = try await runtime.setExternalSkillEnabled(
                id: importedSkill.id,
                enabled: false
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
            XCTAssertEqual(snapshot.settings.loopEngine, .grok)
            XCTAssertTrue(snapshot.loopEngines.allSatisfy {
                $0.harnessOnly
                    && $0.transportOwner == "lingshu"
                    && $0.nativeAuthDisabled
                    && $0.nativeQuotaDisabled
            })
            XCTAssertFalse(snapshot.providerConfigured)
            XCTAssertEqual(snapshot.queuedTaskCount, 0)
            XCTAssertEqual(imported.imported, 1)
            XCTAssertEqual(snapshot.memory?.totalCount, 1)
            XCTAssertEqual(snapshot.memory?.countsByKind["preference"], 1)
            XCTAssertEqual(importedSkill.name, "portable-bridge-skill")
            XCTAssertEqual(importedSkill.sourceFormat, .openAgentSkill)
            XCTAssertEqual(listedSkills.map(\.id), [importedSkill.id])
            XCTAssertEqual(
                refreshedSkills.first?.description,
                "Verify that explicit refresh re-reads the external Skill source."
            )
            XCTAssertEqual(refreshedSkills.first?.modelInvocationEnabled, false)
            XCTAssertFalse(disabledSkill.enabled)
            XCTAssertEqual(snapshot.externalSkills.map(\.id), [importedSkill.id])
            XCTAssertFalse(snapshot.externalSkills[0].enabled)
            XCTAssertFalse(snapshot.externalSkills[0].modelInvocationEnabled)

            let removedSkill = try await runtime.removeExternalSkill(id: importedSkill.id)
            let remainingSkills = try await runtime.listExternalSkills()
            XCTAssertTrue(removedSkill)
            XCTAssertTrue(FileManager.default.fileExists(atPath: skillManifest.path))
            XCTAssertTrue(remainingSkills.isEmpty)
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
