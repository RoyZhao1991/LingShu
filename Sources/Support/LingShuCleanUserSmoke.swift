import Foundation

@MainActor
enum LingShuCleanUserSmokeProbe {
    private(set) static var languageSelectionPresented = false
    private(set) static var brainSetupPresented = false

    static func recordLanguageSelectionPresented() {
        guard LingShuRuntimeEnvironment.isCleanUserSmoke else { return }
        languageSelectionPresented = true
    }

    static func recordBrainSetupPresented() {
        guard LingShuRuntimeEnvironment.isCleanUserSmoke else { return }
        brainSetupPresented = true
    }
}

struct LingShuCleanUserSmokeResult: Codable, Equatable {
    struct Checks: Codable, Equatable {
        var notarizedDMG = false
        var installedPayloadSignature = false
        var appAliveAfterResult = false
        var initialLanguageSelectionPresented: Bool
        var brainSetupPresentedWithoutConfiguration: Bool
        var applicationSupportIsolated: Bool
        var preferencesIsolated: Bool
        var keychainAccessDisabled: Bool
        var taskHistoryInitiallyEmpty: Bool
        var permissionServicesDisabled: Bool
        var minimalDirectReplyCompleted: Bool
    }

    var schemaVersion = 1
    var source: String
    var processID: Int32
    var createdAtUTC: String
    var isolatedRoot: String
    var applicationSupportRoot: String
    var replyPreview: String
    var checks: Checks
}

@MainActor
enum LingShuCleanUserSmokeCoordinator {
    static func runIfRequested(state: LingShuState) async {
        guard let configuration = LingShuRuntimeEnvironment.cleanUserSmoke else { return }

        state.voiceOutputEnabled = false
        let taskHistoryInitiallyEmpty = state.taskExecutionRecords.isEmpty
        let languagePresented = await waitUntil { LingShuCleanUserSmokeProbe.languageSelectionPresented }

        if !state.hasCompletedInitialLanguageSelection {
            state.completeInitialLanguageSelection(.chinese)
        }

        _ = await state.prepareBrainOnLaunch()
        let brainSetupPresented = await waitUntil { LingShuCleanUserSmokeProbe.brainSetupPresented }

        let reply = state.submitTextInput("现在几点？", source: .typed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appSupport = LingShuRuntimeEnvironment.applicationSupportDirectory()
        let preferencesRoot = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let result = LingShuCleanUserSmokeResult(
            source: configuration.source,
            processID: ProcessInfo.processInfo.processIdentifier,
            createdAtUTC: ISO8601DateFormatter().string(from: Date()),
            isolatedRoot: configuration.root.path,
            applicationSupportRoot: appSupport.path,
            replyPreview: String(reply.prefix(120)),
            checks: .init(
                initialLanguageSelectionPresented: languagePresented,
                brainSetupPresentedWithoutConfiguration: brainSetupPresented && state.brainSetupPhase.shouldPresentWizard,
                applicationSupportIsolated: LingShuRuntimeEnvironment.isInsideCleanUserRoot(appSupport),
                preferencesIsolated: preferencesRoot.map(LingShuRuntimeEnvironment.isInsideCleanUserRoot) == true,
                keychainAccessDisabled: !LingShuRuntimeEnvironment.allowsKeychainAccess,
                taskHistoryInitiallyEmpty: taskHistoryInitiallyEmpty,
                permissionServicesDisabled: !LingShuRuntimeEnvironment.allowsPermissionServices,
                minimalDirectReplyCompleted: !reply.isEmpty
            )
        )

        do {
            let data = try JSONEncoder.pretty.encode(result)
            try data.write(to: configuration.resultFile, options: .atomic)
        } catch {
            let message = "clean-user smoke result failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    private static func waitUntil(
        attempts: Int = 80,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
