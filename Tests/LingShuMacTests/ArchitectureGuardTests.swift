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
        XCTAssertTrue(document.contains("文本、Markdown、PDF、PPTX、HTML、JSON、CSV"))
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
        XCTAssertFalse(appEntry.contains("LingShuModelGateway"))
        XCTAssertFalse(appEntry.contains("LingShuExternalAgentGateway"))
    }

    func testViewsDoNotDirectlyCallInfrastructureAdapters() throws {
        let viewFiles = try swiftFiles(under: "Sources/Views")
        let forbiddenTokens = [
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

    func testSwiftUIControlsDoNotBypassInterfaceLocalization() throws {
        let controlTokens = [
            "Text(", "Label(", "Button(", "Toggle(", "Picker(",
            "TextField(", "SecureField(", ".help("
        ]

        for file in try swiftFiles(under: "Sources/Views") where file.lastPathComponent != "LingShuInitialLanguageSelectionView.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, rawLine) in lines.enumerated() {
                let line = String(rawLine)
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
                guard controlTokens.contains(where: code.contains) else { continue }
                guard code.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { continue }
                guard !code.contains("state.loc("),
                      !code.contains("LingShuLanguagePreferenceStore.localized("),
                      !code.contains("Text(loc("),
                      !code.contains("Button(loc(")
                else { continue }

                XCTFail("\(file.lastPathComponent):\(index + 1) contains a direct Chinese SwiftUI control string; route it through the interface language store")
            }
        }
    }

    func testGoalSpecGenerationNeverBranchesOnModelOrProviderIdentity() throws {
        let files = [
            "Sources/State/LingShuState+GoalSpec.swift",
            "Sources/State/LingShuState+GoalSpecGeneration.swift",
            "Sources/State/LingShuState+GoalSpecHistoryResolution.swift",
            "Sources/Support/LingShuGoalSpecGenerationPolicy.swift"
        ]
        let forbiddenPatterns = [
            #"\b(if|guard|while)\b[^\{\n]{0,320}\b(modelName|modelProvider)\b"#,
            #"\bswitch\s+(self\.)?(modelName|modelProvider)\b"#,
            #"\b(modelName|modelProvider)\s*\.\s*(lowercased|uppercased|contains|hasPrefix|hasSuffix)\b"#
        ]

        for relativePath in files {
            let source = try readText(relativePath)
            for pattern in forbiddenPatterns {
                XCTAssertNil(
                    source.range(of: pattern, options: .regularExpression),
                    "\(relativePath) must negotiate GoalSpec behavior by protocol/capability response, never by model or provider identity"
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
            "Sources/Views/LingShuPerceptionComponents.swift",
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
            "Sources/Services/LingShuLocalDocumentArtifactBuilder.swift",
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

    func testInfrastructureFilesStayBelowHardSplitThreshold() throws {
        // 800 行硬上限：Infrastructure 适配器按职责拆分,单文件不超 800 行。
        let infraFiles = try swiftFiles(under: "Sources/Infrastructure")
        for file in infraFiles {
            XCTAssertLessThanOrEqual(
                try lineCount(of: file),
                800,
                "\(file.lastPathComponent) exceeds the 800-line hard split threshold"
            )
        }
    }

    func testViewFilesLiveUnderViewsFolder() throws {
        // 视图文件必须在 Sources/Views 下，不得散落在 Sources 根目录。
        let rootSwift = try FileManager.default.contentsOfDirectory(
            at: projectRoot.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for file in rootSwift {
            let text = try String(contentsOf: file, encoding: .utf8)
            let looksLikeView = text.contains(": View {") || text.contains("some View")
            XCTAssertFalse(
                looksLikeView && file.lastPathComponent != "LingShuMac.swift",
                "\(file.lastPathComponent) is a SwiftUI view and must live under Sources/Views"
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

    func testValidationArtifactsStayIgnoredAndUntracked() throws {
        let gitignore = try readText(".gitignore")
        for pattern in ["ValidationArtifacts/", ".lingshu-e2e-output/", "验收结果.*", "Resources/RuntimeConfig/*.token"] {
            XCTAssertTrue(gitignore.contains(pattern), ".gitignore must keep local artifact/credential pattern: \(pattern)")
        }

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("无 git") }
        let tracked = try gitOutput([
            "ls-files",
            "ValidationArtifacts",
            ".lingshu-e2e-output",
            "验收结果.pdf",
            "验收结果.txt"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(tracked.isEmpty, "local E2E/probe artifacts must not be tracked:\n\(tracked)")
    }

    func testDistributionScriptsPinTrustedSystemPath() throws {
        let trustedPath = #"PATH="/usr/bin:/bin:/usr/sbin:/sbin""#
        let releaseScript = try readText("Scripts/release-website.sh")
        let buildScript = try readText("Scripts/build-app.sh")

        guard
            let releasePath = releaseScript.range(of: trustedPath),
            let releaseRoot = releaseScript.range(of: "ROOT_DIR=")
        else {
            return XCTFail("website release script must pin the Apple/system PATH before resolving the checkout")
        }

        XCTAssertLessThan(releasePath.lowerBound, releaseRoot.lowerBound)
        XCTAssertFalse(releaseScript.contains("/opt/homebrew"))
        XCTAssertFalse(releaseScript.contains("/usr/local/bin"))
        XCTAssertTrue(buildScript.contains(#"if [ "${LINGSHU_REQUIRE_DISTRIBUTION_SIGNING:-0}" = "1" ]"#))
        XCTAssertTrue(buildScript.contains(trustedPath))
        XCTAssertTrue(releaseScript.contains(#"TEAM_ID="${LINGSHU_APPLE_TEAM_ID:-KM7N84AC9Y}""#))
        XCTAssertTrue(releaseScript.contains("EXPECTED_CERT_SHA256="))
        XCTAssertTrue(releaseScript.contains("signing_certificate_sha256"))
        XCTAssertTrue(releaseScript.contains("signing certificate fingerprint mismatch"))
        XCTAssertTrue(buildScript.contains("BUILD_TMP_ROOT="))
        XCTAssertTrue(buildScript.contains(#"SCRATCH_PATH="$BUILD_TMP_ROOT/scratch-$ARCH""#))
        XCTAssertTrue(buildScript.contains("distribution builds always start from an isolated empty graph"))
        XCTAssertTrue(releaseScript.contains(#"LINGSHU_SOURCE_REVISION="$SOURCE_REVISION""#))
        XCTAssertTrue(releaseScript.contains("bundled source revision mismatch"))
        XCTAssertTrue(releaseScript.contains("source_archive_sha256"))
        XCTAssertTrue(releaseScript.contains("app_binary_sha256"))
        XCTAssertTrue(releaseScript.contains("cli_binary_sha256"))
        XCTAssertTrue(releaseScript.contains("LINGSHU_NOTARY_NO_S3_ACCELERATION"))
        XCTAssertTrue(releaseScript.contains("detach_image_path"))
        XCTAssertTrue(releaseScript.contains(#"hdiutil verify "$DMG_PATH""#))
    }

    func testArchitectureQuickReferenceStatesCurrentCodeReality() throws {
        let document = try readText("Docs/架构速查手册.md")
        let requiredMarkers = [
            "最后更新:2026-07-16",
            "LingShuAgentOrchestrator(maxConcurrent:1)",
            "pendingSerialInputs",
            "GoalSpec 不可变,运行图可变",
            "人机协作 ≠ 失败",
            "OAuth 只认 OAuth 标识",
            "FullStackE2E200Tests",
            "不能直接当当前 HEAD 绿灯",
            "表内带日期的“实测 / 全量 N 测试 0 失败”",
            "旧 `DirectChat`/`LocalAnswers`/`TaskResume` 已不存在"
        ]

        for marker in requiredMarkers {
            XCTAssertTrue(document.contains(marker), "架构速查手册缺少当前代码态标记: \(marker)")
        }

        XCTAssertFalse(
            document.contains("`submitTextInput` 唯一出口= `runMainAgentTurn`"),
            "架构速查手册不能再把旧主会话路径写成当前唯一出口"
        )
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

    private func gitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = projectRoot
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed: \(errorText)")
        return text
    }
}
