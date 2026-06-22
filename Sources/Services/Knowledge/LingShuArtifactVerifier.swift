import Foundation
import ImageIO

/// 完全版 #3·**产出物验收协议 + 注册表**(按类型验收,可插拔)。
///
/// 取向(不推翻现有验收):现有 maker≠checker LLM verifier + 测试门/运行门 + nested 文件存在核对都保留;
/// 这里把"按交付物类型的**确定性**验收"收口成可插拔注册表——加新类型 = 注册一个 verifier,不改验收主流程。
/// 默认只跑**确定性层**(快、无 LLM,适合 nested per-stage 高频调用,避免跨阶段 LLM 误判);
/// 运行/渲染层与语义层作为更重的可选层,由主验收路径按需触发(协议留好接缝)。
enum LingShuArtifactKind: String, Sendable, Equatable {
    case code, ppt, pdf, markdown, document, data, image, audio, video, generic
}

struct LingShuArtifactCheck: Sendable, Equatable {
    let layer: String      // 确定性 / 运行渲染 / 语义
    let passed: Bool
    let detail: String
}

struct LingShuArtifactVerdict: Sendable, Equatable {
    let path: String
    let kind: LingShuArtifactKind
    let passed: Bool
    let checks: [LingShuArtifactCheck]
}

/// 单类型 verifier。`verifyDeterministic` 必有(快);更重的层默认空(由具体 verifier 覆盖)。
protocol LingShuArtifactVerifier: Sendable {
    var kind: LingShuArtifactKind { get }
    func verifyDeterministic(path: String) -> LingShuArtifactCheck
}

// MARK: - 类型识别(按扩展名,数据非控制分支)

enum LingShuArtifactKindDetector {
    static let byExt: [String: LingShuArtifactKind] = [
        "swift": .code, "py": .code, "js": .code, "ts": .code, "java": .code, "go": .code, "rs": .code,
        "c": .code, "cpp": .code, "rb": .code, "sh": .code,
        "pptx": .ppt, "ppt": .ppt, "key": .ppt,
        "pdf": .pdf, "md": .markdown, "markdown": .markdown,
        "txt": .document, "doc": .document, "docx": .document, "rtf": .document,
        "json": .data, "csv": .data, "tsv": .data, "yaml": .data, "yml": .data, "xml": .data,
        "png": .image, "jpg": .image, "jpeg": .image, "heic": .image, "gif": .image, "tiff": .image,
        "wav": .audio, "mp3": .audio, "m4a": .audio, "aac": .audio,
        "mp4": .video, "mov": .video, "m4v": .video
    ]
    static func kind(forPath path: String) -> LingShuArtifactKind {
        byExt[(path as NSString).pathExtension.lowercased()] ?? .generic
    }
}

// MARK: - 确定性验收的共享原语(纯逻辑/文件,可测)

enum LingShuArtifactFileCheck {
    static func size(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }
    static func existsNonEmpty(_ path: String) -> (ok: Bool, detail: String) {
        guard let s = size(path) else { return (false, "文件不存在") }
        return s > 0 ? (true, "存在且 \(s) 字节") : (false, "存在但为空")
    }
}

// MARK: - 默认 verifier 实现(确定性层)

struct LingShuGenericFileVerifier: LingShuArtifactVerifier {
    let kind: LingShuArtifactKind = .generic
    func verifyDeterministic(path: String) -> LingShuArtifactCheck {
        let r = LingShuArtifactFileCheck.existsNonEmpty(path)
        return .init(layer: "确定性", passed: r.ok, detail: r.detail)
    }
}

/// 文档/Markdown:存在 + 非空 + 正文有实质长度(防只写个标题就交)。
struct LingShuDocumentVerifier: LingShuArtifactVerifier {
    let kind: LingShuArtifactKind
    let minChars: Int
    init(kind: LingShuArtifactKind = .document, minChars: Int = 20) { self.kind = kind; self.minChars = minChars }
    func verifyDeterministic(path: String) -> LingShuArtifactCheck {
        let r = LingShuArtifactFileCheck.existsNonEmpty(path)
        guard r.ok else { return .init(layer: "确定性", passed: false, detail: r.detail) }
        let text = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.count >= minChars
            ? .init(layer: "确定性", passed: true, detail: "正文 \(text.count) 字")
            : .init(layer: "确定性", passed: false, detail: "正文过短(\(text.count)<\(minChars)),疑似空交付")
    }
}

/// 数据:存在 + 格式合法(JSON 可解析 / CSV 有数据行)。
struct LingShuDataVerifier: LingShuArtifactVerifier {
    let kind: LingShuArtifactKind = .data
    func verifyDeterministic(path: String) -> LingShuArtifactCheck {
        let r = LingShuArtifactFileCheck.existsNonEmpty(path)
        guard r.ok else { return .init(layer: "确定性", passed: false, detail: r.detail) }
        let ext = (path as NSString).pathExtension.lowercased()
        guard let data = FileManager.default.contents(atPath: path) else {
            return .init(layer: "确定性", passed: false, detail: "读不到内容")
        }
        if ext == "json" {
            let ok = (try? JSONSerialization.jsonObject(with: data)) != nil
            return .init(layer: "确定性", passed: ok, detail: ok ? "JSON 合法" : "JSON 解析失败")
        }
        // csv/tsv:至少 2 行(含表头+数据)。
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.count >= 2 ? .init(layer: "确定性", passed: true, detail: "\(lines.count) 行")
                                : .init(layer: "确定性", passed: false, detail: "数据行不足")
    }
}

/// 图片:存在 + 可被解码(真是图片,不是改了扩展名的垃圾)。
struct LingShuImageVerifier: LingShuArtifactVerifier {
    let kind: LingShuArtifactKind = .image
    func verifyDeterministic(path: String) -> LingShuArtifactCheck {
        let r = LingShuArtifactFileCheck.existsNonEmpty(path)
        guard r.ok else { return .init(layer: "确定性", passed: false, detail: r.detail) }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else {
            return .init(layer: "确定性", passed: false, detail: "无法解码为图片")
        }
        return .init(layer: "确定性", passed: true, detail: "图片可解码")
    }
}

/// PPT/PDF:确定性层只判存在+非空(渲染/页数属更重的可选层,nested per-stage 不强跑以保速)。
struct LingShuBinaryDocVerifier: LingShuArtifactVerifier {
    let kind: LingShuArtifactKind
    func verifyDeterministic(path: String) -> LingShuArtifactCheck {
        let r = LingShuArtifactFileCheck.existsNonEmpty(path)
        return .init(layer: "确定性", passed: r.ok, detail: r.detail)
    }
}

// MARK: - 注册表(单一调度点)

final class LingShuArtifactVerifierRegistry: @unchecked Sendable {
    static let shared = LingShuArtifactVerifierRegistry()
    private let lock = NSLock()
    private var verifiers: [LingShuArtifactKind: any LingShuArtifactVerifier] = [:]
    private let generic = LingShuGenericFileVerifier()

    init() {
        register(LingShuDocumentVerifier(kind: .document))
        register(LingShuDocumentVerifier(kind: .markdown))
        register(LingShuDataVerifier())
        register(LingShuImageVerifier())
        register(LingShuBinaryDocVerifier(kind: .ppt))
        register(LingShuBinaryDocVerifier(kind: .pdf))
        register(LingShuBinaryDocVerifier(kind: .code))   // 代码确定性层=存在;运行/测试门在主验收路径
    }

    func register(_ v: any LingShuArtifactVerifier) {
        lock.lock(); verifiers[v.kind] = v; lock.unlock()
    }

    /// 按路径类型确定性验收一个产出物。
    func verify(path: String) -> LingShuArtifactVerdict {
        let kind = LingShuArtifactKindDetector.kind(forPath: path)
        lock.lock(); let v = verifiers[kind] ?? generic; lock.unlock()
        let check = v.verifyDeterministic(path: path)
        return .init(path: path, kind: kind, passed: check.passed, checks: [check])
    }

    /// 批量(nested 阶段声称的多个产出物):返回(全过, 各判定)。
    func verifyAll(paths: [String]) -> (allPassed: Bool, verdicts: [LingShuArtifactVerdict]) {
        let verdicts = paths.map { verify(path: $0) }
        return (verdicts.allSatisfy { $0.passed }, verdicts)
    }
}
