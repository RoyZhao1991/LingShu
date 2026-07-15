import Foundation

struct LingShuEmbeddedTTSRuntimeStatus: Equatable, Sendable {
    var providerID: String
    var displayName: String
    var isAvailable: Bool
    var selectedRootPath: String?
    var runtimePath: String?
    var modelPath: String?
    var tokensPath: String?
    var lexiconPath: String?
    var dictDirPath: String?
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

enum LingShuEmbeddedTTSRuntimeLocator {
    static let sherpaTTSProviderID = "embedded-sherpa-onnx-tts"

    static func sherpaONNXTTSStatus(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        includeDefaultRoots: Bool = true,
        extraSearchRoots: [URL] = []
    ) -> LingShuEmbeddedTTSRuntimeStatus {
        let roots = (includeDefaultRoots ? defaultSpeechOutputSearchRoots(bundle: bundle, fileManager: fileManager) : []) + extraSearchRoots
        let uniqueRoots = deduplicate(roots)
        let selected = uniqueRoots
            .map { inspectSpeechOutputRoot($0, fileManager: fileManager) }
            .sorted { lhs, rhs in
                if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable && !rhs.isAvailable }
                return lhs.missingItems.count < rhs.missingItems.count
            }
            .first

        if let selected {
            return selected
        }

        return .init(
            providerID: sherpaTTSProviderID,
            displayName: "本地中文男声",
            isAvailable: false,
            selectedRootPath: nil,
            runtimePath: nil,
            modelPath: nil,
            tokensPath: nil,
            lexiconPath: nil,
            dictDirPath: nil,
            missingItems: ["sherpa-onnx-offline-tts", "model.onnx", "tokens.txt"],
            searchPaths: uniqueRoots.map(\.path),
            installHint: installHint(for: uniqueRoots.first)
        )
    }

    static func defaultSpeechOutputSearchRoots(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> [URL] {
        var roots: [URL] = []

        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL.appendingPathComponent("Models/SpeechOutput", isDirectory: true))
            roots.append(resourceURL.appendingPathComponent("Models/sherpa-onnx-tts", isDirectory: true))
        }

        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let lingShuSupport = applicationSupport.appendingPathComponent("LingShu", isDirectory: true)
            roots.append(lingShuSupport.appendingPathComponent("Models/SpeechOutput", isDirectory: true))
            roots.append(lingShuSupport.appendingPathComponent("Models/sherpa-onnx-tts", isDirectory: true))
            roots.append(lingShuSupport.appendingPathComponent("TTS/SherpaONNX", isDirectory: true))
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for root in [URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true), sourceRoot] {
            roots.append(root.appendingPathComponent("Models/SpeechOutput", isDirectory: true))
            roots.append(root.appendingPathComponent("Models/sherpa-onnx-tts", isDirectory: true))
        }

        return roots
    }

    static func processArguments(
        status: LingShuEmbeddedTTSRuntimeStatus,
        text: String,
        persona: LingShuSpeechPersona,
        outputURL: URL
    ) throws -> [String] {
        guard let modelPath = status.modelPath,
              let tokensPath = status.tokensPath else {
            throw LingShuVoiceError.embeddedRuntimeUnavailable(status.diagnosticSummary)
        }

        var arguments = [
            "--vits-model=\(modelPath)",
            "--vits-tokens=\(tokensPath)",
            "--sid=\(persona.speakerID)",
            "--speed=\(persona.speed)",
            "--output-filename=\(outputURL.path)",
            "--num-threads=2",
            "--provider=cpu"
        ]

        if let lexiconPath = status.lexiconPath {
            arguments.append("--vits-lexicon=\(lexiconPath)")
        }

        if let dictDirPath = status.dictDirPath {
            arguments.append("--vits-dict-dir=\(dictDirPath)")
        }

        arguments.append(text)
        return arguments
    }

    static func dynamicLibraryPath(for runtimePath: String) -> String {
        URL(fileURLWithPath: runtimePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib", isDirectory: true)
            .path
    }

    private static func inspectSpeechOutputRoot(
        _ root: URL,
        fileManager: FileManager
    ) -> LingShuEmbeddedTTSRuntimeStatus {
        let runtimePath = firstExistingPath(candidates: runtimeCandidates(in: root), fileManager: fileManager)
        let modelPath = firstExistingPath(candidates: modelCandidates(in: root), fileManager: fileManager)
        let tokensPath = firstExistingPath(candidates: tokenCandidates(in: root), fileManager: fileManager)
        let lexiconPath = firstExistingPath(candidates: lexiconCandidates(in: root), fileManager: fileManager)
        let dictDirPath = firstExistingPath(candidates: dictDirCandidates(in: root), fileManager: fileManager)

        var missingItems: [String] = []
        if runtimePath == nil { missingItems.append("sherpa-onnx-offline-tts") }
        if modelPath == nil { missingItems.append("TTS model.onnx") }
        if tokensPath == nil { missingItems.append("tokens.txt") }

        return .init(
            providerID: sherpaTTSProviderID,
            displayName: "本地中文男声",
            isAvailable: missingItems.isEmpty,
            selectedRootPath: missingItems.isEmpty ? root.path : nil,
            runtimePath: runtimePath?.path,
            modelPath: modelPath?.path,
            tokensPath: tokensPath?.path,
            lexiconPath: lexiconPath?.path,
            dictDirPath: dictDirPath?.path,
            missingItems: missingItems,
            searchPaths: [root.path],
            installHint: installHint(for: root)
        )
    }

    private static func runtimeCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("bin/sherpa-onnx-offline-tts", isDirectory: false),
            root.appendingPathComponent("runtime/sherpa-onnx-offline-tts", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-offline-tts", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-v1.13.2-osx-arm64-shared/bin/sherpa-onnx-offline-tts", isDirectory: false),
            root.appendingPathComponent("sherpa-onnx-v1.13.2-osx-universal2-shared/bin/sherpa-onnx-offline-tts", isDirectory: false)
        ]
    }

    private static func modelCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("model.onnx", isDirectory: false),
            root.appendingPathComponent("vits-icefall-zh-aishell3/model.onnx", isDirectory: false),
            root.appendingPathComponent("model/model.onnx", isDirectory: false)
        ]
    }

    private static func tokenCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("tokens.txt", isDirectory: false),
            root.appendingPathComponent("vits-icefall-zh-aishell3/tokens.txt", isDirectory: false),
            root.appendingPathComponent("model/tokens.txt", isDirectory: false)
        ]
    }

    private static func lexiconCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("lexicon.txt", isDirectory: false),
            root.appendingPathComponent("vits-icefall-zh-aishell3/lexicon.txt", isDirectory: false),
            root.appendingPathComponent("model/lexicon.txt", isDirectory: false)
        ]
    }

    private static func dictDirCandidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("dict", isDirectory: true),
            root.appendingPathComponent("vits-icefall-zh-aishell3/dict", isDirectory: true),
            root.appendingPathComponent("model/dict", isDirectory: true)
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
        let rootPath = root?.path ?? "~/Library/Application Support/LingShu/Models/SpeechOutput"
        return "把 sherpa-onnx TTS runtime 和中文 VITS 模型放入 \(rootPath)。"
    }
}
