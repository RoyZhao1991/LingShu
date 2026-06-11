import Foundation

struct LingShuEmbeddedASRRuntimeStatus: Equatable, Sendable {
    var providerID: String
    var displayName: String
    var isAvailable: Bool
    var selectedRootPath: String?
    var runtimePath: String?
    var modelPath: String?
    var tokensPath: String?
    var vadModelPath: String?
    var missingItems: [String]
    var searchPaths: [String]
    var installHint: String

    var activationNote: String {
        if let selectedRootPath {
            return "\(displayName) 已就绪：\(selectedRootPath)"
        }

        return "\(displayName) 已就绪。"
    }

    var diagnosticSummary: String {
        guard !isAvailable else { return activationNote }

        let missing = missingItems.isEmpty ? "运行时或模型文件" : missingItems.joined(separator: " / ")
        return "\(displayName) 未就绪：缺少 \(missing)。\(installHint)"
    }

    var compactDiagnostic: String {
        guard !isAvailable else { return "已就绪" }
        return missingItems.isEmpty ? "未安装" : "缺少 \(missingItems.joined(separator: "、"))"
    }
}

enum LingShuEmbeddedASRRuntimeLocator {
    static let senseVoiceProviderID = "sensevoice-sherpa-onnx"

    static func senseVoiceSherpaONNXStatus(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        includeDefaultRoots: Bool = true,
        extraSearchRoots: [URL] = []
    ) -> LingShuEmbeddedASRRuntimeStatus {
        let roots = (includeDefaultRoots ? defaultSenseVoiceSearchRoots(bundle: bundle, fileManager: fileManager) : []) + extraSearchRoots
        let uniqueRoots = deduplicate(roots)
        let selected = uniqueRoots
            .map { inspectSenseVoiceRoot($0, fileManager: fileManager) }
            .sorted { lhs, rhs in
                if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable && !rhs.isAvailable }
                return lhs.missingItems.count < rhs.missingItems.count
            }
            .first

        if let selected {
            return selected
        }

        return .init(
            providerID: senseVoiceProviderID,
            displayName: "SenseVoice / sherpa-onnx",
            isAvailable: false,
            selectedRootPath: nil,
            runtimePath: nil,
            modelPath: nil,
            tokensPath: nil,
            vadModelPath: nil,
            missingItems: ["runtime", "model.onnx", "tokens.txt", "silero_vad.onnx"],
            searchPaths: uniqueRoots.map(\.path),
            installHint: installHint(for: uniqueRoots.first)
        )
    }

    static func defaultSenseVoiceSearchRoots(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> [URL] {
        var roots: [URL] = []

        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL.appendingPathComponent("Models/SenseVoice", isDirectory: true))
            roots.append(resourceURL.appendingPathComponent("Models/sensevoice-sherpa-onnx", isDirectory: true))
        }

        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let lingShuSupport = applicationSupport.appendingPathComponent("LingShu", isDirectory: true)
            roots.append(lingShuSupport.appendingPathComponent("Models/SenseVoice", isDirectory: true))
            roots.append(lingShuSupport.appendingPathComponent("Models/sensevoice-sherpa-onnx", isDirectory: true))
            roots.append(lingShuSupport.appendingPathComponent("ASR/SenseVoice", isDirectory: true))
        }

        roots.append(URL(fileURLWithPath: "/Users/example/app/LingShuMac/Models/SenseVoice", isDirectory: true))
        roots.append(URL(fileURLWithPath: "/Users/example/app/LingShuMac/Models/sensevoice-sherpa-onnx", isDirectory: true))

        return roots
    }

    private static func inspectSenseVoiceRoot(
        _ root: URL,
        fileManager: FileManager
    ) -> LingShuEmbeddedASRRuntimeStatus {
        let runtimePath = firstExistingPath(
            candidates: runtimeCandidates(in: root),
            fileManager: fileManager
        )
        let modelPath = firstExistingPath(
            candidates: modelCandidates(in: root),
            fileManager: fileManager
        )
        let tokensPath = firstExistingPath(
            candidates: tokenCandidates(in: root),
            fileManager: fileManager
        )
        let vadModelPath = firstExistingPath(
            candidates: vadModelCandidates(in: root),
            fileManager: fileManager
        )

        var missingItems: [String] = []
        if runtimePath == nil { missingItems.append("sherpa-onnx microphone runtime") }
        if modelPath == nil { missingItems.append("SenseVoice model.onnx") }
        if tokensPath == nil { missingItems.append("tokens.txt") }
        if vadModelPath == nil { missingItems.append("silero_vad.onnx") }

        return .init(
            providerID: senseVoiceProviderID,
            displayName: "SenseVoice / sherpa-onnx",
            isAvailable: missingItems.isEmpty,
            selectedRootPath: missingItems.isEmpty ? root.path : nil,
            runtimePath: runtimePath?.path,
            modelPath: modelPath?.path,
            tokensPath: tokensPath?.path,
            vadModelPath: vadModelPath?.path,
            missingItems: missingItems,
            searchPaths: [root.path],
            installHint: installHint(for: root)
        )
    }

    private static func runtimeCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("runtime/sherpa-onnx-vad-microphone-offline-asr", isDirectory: false),
            root.appendingPathComponent("bin/sherpa-onnx-vad-microphone-offline-asr", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-vad-microphone-offline-asr", isDirectory: false),
            root.appendingPathComponent("runtime/sherpa-onnx-offline", isDirectory: false),
            root.appendingPathComponent("runtime/sherpa-onnx", isDirectory: false),
            root.appendingPathComponent("bin/sherpa-onnx-offline", isDirectory: false),
            root.appendingPathComponent("bin/sherpa-onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-offline", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts/bin/sherpa-onnx-vad-microphone-offline-asr", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-v1.13.2-osx-universal2-shared-no-tts/bin/sherpa-onnx-vad-microphone-offline-asr", isDirectory: false),
            root.appendingPathComponent("lib/libsherpa-onnx.dylib", isDirectory: false),
            root.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib", isDirectory: false),
            root.appendingPathComponent("SherpaOnnx.xcframework", isDirectory: true),
            root.appendingPathComponent("sherpa-onnx.xcframework", isDirectory: true)
        ]
    }

    private static func modelCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("model.onnx", isDirectory: false),
            root.appendingPathComponent("model.int8.onnx", isDirectory: false),
            root.appendingPathComponent("sense-voice.onnx", isDirectory: false),
            root.appendingPathComponent("sense-voice-int8.onnx", isDirectory: false),
            root.appendingPathComponent("model/model.onnx", isDirectory: false),
            root.appendingPathComponent("model/model.int8.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/model.int8.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/model.int8.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09/model.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.onnx", isDirectory: false)
        ]
    }

    private static func tokenCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("tokens.txt", isDirectory: false),
            root.appendingPathComponent("model/tokens.txt", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/tokens.txt", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/tokens.txt", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09/tokens.txt", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt", isDirectory: false)
        ]
    }

    private static func vadModelCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("silero_vad.onnx", isDirectory: false),
            root.appendingPathComponent("vad/silero_vad.onnx", isDirectory: false),
            root.appendingPathComponent("model/silero_vad.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/silero_vad.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/silero_vad.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09/silero_vad.onnx", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/silero_vad.onnx", isDirectory: false)
        ]
    }

    private static func firstExistingPath(candidates: [URL], fileManager: FileManager) -> URL? {
        candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func installHint(for root: URL?) -> String {
        let rootPath = root?.path ?? "~/Library/Application Support/LingShu/Models/SenseVoice"
        return "把 sherpa-onnx macOS runtime 和 SenseVoice ONNX 模型放入 \(rootPath)。"
    }
}

