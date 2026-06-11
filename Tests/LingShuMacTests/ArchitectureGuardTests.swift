import XCTest

final class ArchitectureGuardTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testArchitectureStandardDocumentsExpandableAgentBoundaries() throws {
        let document = try readText("Docs/ARCHITECTURE.md")

        XCTAssertTrue(document.contains("灵枢主线程只做判断、记忆恢复、能力编排、权限裁决、验收和统一回复"))
        XCTAssertTrue(document.contains("实时感知能力必须分三层"))
        XCTAssertTrue(document.contains("设计部是通用设计交付能力"))
        XCTAssertTrue(document.contains("每条用户消息必须创建任务执行记录"))
        XCTAssertTrue(document.contains("默认热加载最近 3 天的聊天历史"))
        XCTAssertTrue(document.contains("身份锁开启后，触发词命中也必须先通过面容和声线联合确认"))
        XCTAssertTrue(document.contains("外部 agent 接入必须通过注册表和网关"))
    }

    func testAppEntryRemainsAThinBootLayer() throws {
        let appEntry = try readText("Sources/LingShuMac.swift")
        let executableLines = appEntry
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        XCTAssertLessThanOrEqual(executableLines.count, 200)
        XCTAssertFalse(appEntry.contains("CodexBridge"))
        XCTAssertFalse(appEntry.contains("LingShuModelGateway"))
        XCTAssertFalse(appEntry.contains("LingShuExternalAgentGateway"))
    }

    func testViewsDoNotDirectlyCallInfrastructureAdapters() throws {
        let viewFiles = try swiftFiles(under: "Sources/Views")
        let forbiddenTokens = [
            "CodexBridge",
            "LingShuModelGateway(",
            "LingShuExternalAgentGateway(",
            "URLSession.shared",
            "Process()",
            "Process("
        ]

        for file in viewFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(
                    text.contains(token),
                    "\(file.lastPathComponent) must not directly use infrastructure token \(token)"
                )
            }
        }
    }

    func testNoMeaninglessAgentReadinessCopyReturnsToPrimaryViews() throws {
        let scannedFiles = try swiftFiles(under: "Sources/Views") + swiftFiles(under: "Sources/Domain")
        let forbiddenCopy = [
            "agent集群已就绪",
            "各部门 agent 实时状态",
            "工程六部",
            "三省六部"
        ]

        for file in scannedFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for copy in forbiddenCopy {
                XCTAssertFalse(
                    text.contains(copy),
                    "\(file.lastPathComponent) contains non-operational copy: \(copy)"
                )
            }
        }
    }

    func testVoiceServiceFilesStayBelowHardSplitThreshold() throws {
        let voiceFiles = try swiftFiles(under: "Sources/Services/Voice")
            + [projectRoot.appendingPathComponent("Sources/Services/VoiceIOManager.swift")]

        for file in voiceFiles {
            let lineCount = try lineCount(of: file)
            XCTAssertLessThanOrEqual(
                lineCount,
                800,
                "\(file.lastPathComponent) has grown past the hard split threshold"
            )
        }
    }

    func testPerceptionViewFilesStaySplitByResponsibility() throws {
        let perceptionFiles = [
            "Sources/Views/LingShuPerceptionViews.swift",
            "Sources/Views/LingShuPerceptionActions.swift",
            "Sources/Views/LingShuOwnerIdentityViews.swift",
            "Sources/Views/LingShuPerceptionPanel.swift",
            "Sources/Views/LingShuCameraPreviewView.swift"
        ].map { projectRoot.appendingPathComponent($0) }

        for file in perceptionFiles {
            let lineCount = try lineCount(of: file)
            XCTAssertLessThanOrEqual(
                lineCount,
                500,
                "\(file.lastPathComponent) should stay focused on one perception UI responsibility"
            )
        }
    }

    func testEngineeringArtifactFilesStaySplitByArtifactType() throws {
        let artifactFiles = [
            "Sources/Services/LingShuEngineeringArtifactService.swift",
            "Sources/Services/LingShuCrawlerArtifactBuilder.swift",
            "Sources/Services/LingShuPresentationArtifactBuilder.swift",
            "Sources/Services/LingShuArtifactManifestWriter.swift",
            "Sources/Services/LingShuArtifactFileWriter.swift"
        ].map { projectRoot.appendingPathComponent($0) }

        for file in artifactFiles {
            let lineCount = try lineCount(of: file)
            XCTAssertLessThanOrEqual(
                lineCount,
                500,
                "\(file.lastPathComponent) should stay focused on one artifact responsibility"
            )
        }
    }

    func testMemoryServiceFilesStaySplitByResponsibility() throws {
        let memoryFiles = [
            "Sources/Services/LingShuMemoryService.swift",
            "Sources/Services/Memory/LingShuMemoryTextToolkit.swift",
            "Sources/Services/Memory/LingShuChatHistoryStore.swift"
        ].map { projectRoot.appendingPathComponent($0) }

        for file in memoryFiles {
            let lineCount = try lineCount(of: file)
            XCTAssertLessThanOrEqual(
                lineCount,
                500,
                "\(file.lastPathComponent) should stay focused on one memory responsibility"
            )
        }
    }

    func testPerceptionServiceFilesStaySplitByResponsibility() throws {
        let perceptionFiles = try swiftFiles(under: "Sources/Services/Perception")

        for file in perceptionFiles {
            let lineCount = try lineCount(of: file)
            XCTAssertLessThanOrEqual(
                lineCount,
                500,
                "\(file.lastPathComponent) should stay focused on one perception responsibility"
            )
        }
    }

    func testStateFilesKeepOperationalSubdomainsSplitOut() throws {
        let mainState = projectRoot.appendingPathComponent("Sources/State/LingShuState.swift")
        XCTAssertLessThanOrEqual(
            try lineCount(of: mainState),
            3500,
            "LingShuState.swift should keep shrinking as operational subdomains move into state extensions"
        )

        let stateExtensionFiles = try swiftFiles(under: "Sources/State")
            .filter { $0.lastPathComponent != "LingShuState.swift" }
        XCTAssertFalse(stateExtensionFiles.isEmpty, "LingShuState should have split extension files for operational subdomains")

        for file in stateExtensionFiles {
            XCTAssertLessThanOrEqual(
                try lineCount(of: file),
                500,
                "\(file.lastPathComponent) should stay focused on one state subdomain"
            )
        }
    }

    private func readText(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func lineCount(of file: URL) throws -> Int {
        try String(contentsOf: file, encoding: .utf8).split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count
    }

    private func swiftFiles(under relativePath: String) throws -> [URL] {
        let root = projectRoot.appendingPathComponent(relativePath, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return try (enumerator?.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        } ?? [])
    }
}
