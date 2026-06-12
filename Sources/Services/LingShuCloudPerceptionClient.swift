import Foundation

/// 云端感知专项接口的模型描述（来自 /v1/perception/models）。
struct LingShuCloudPerceptionModel: Equatable, Sendable {
    var id: String
    var displayName: String
    var capability: String
    var route: String
}

/// 感知专项接口的统一结果：图片 / 音频 / 视频共用一个归一化视图。
struct LingShuCloudPerceptionResult: Equatable, Sendable {
    var success: Bool
    var taskType: String
    var transcript: String
    var ocrTexts: [String]
    var detectionCount: Int
    var semanticSuggestions: String
    var warnings: [String]
    var totalTokens: Int?
    var model: String
}

enum LingShuCloudPerceptionError: Error, Equatable {
    case invalidEndpoint
    case missingMediaSource
    case requestFailed(Int, String)
    case malformedResponse
}

/// 数据增值协作网络算力中心网关的感知专项客户端。
///
/// 规则：
/// - 只走网关域名，不直连底层算力服务器或具体模型；
/// - 所有请求携带 `X-Model-Token`；
/// - 小文件可用 base64 字段，生产大文件必须先上传得到可被算力服务器访问的 URL；
/// - 每次调用记录 `usage.total_tokens` 供前端展示用量。
struct LingShuCloudPerceptionClient {
    /// 形如 https://model-gateway.datanet.bj.cn/v1
    var baseEndpoint: URL
    var token: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 300

    // MARK: - 接口

    func listModels() async throws -> [LingShuCloudPerceptionModel] {
        var request = URLRequest(url: perceptionURL(route: "models"))
        request.httpMethod = "GET"
        applyAuthHeaders(&request)

        let data = try await perform(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else {
            throw LingShuCloudPerceptionError.malformedResponse
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return LingShuCloudPerceptionModel(
                id: id,
                displayName: item["display_name"] as? String ?? id,
                capability: item["capability"] as? String ?? "",
                route: item["route"] as? String ?? ""
            )
        }
    }

    /// 实时态势常用检测对象。后端 grounding-dino 只有传了 detection_queries 才执行检测，
    /// 否则 detections 永远为空。
    static let defaultDetectionQueries = ["person", "face", "screen", "document", "phone", "hand"]

    /// 图片快速理解（swds-vision-fast）。include_qwen_semantics 默认开——服务端已部署
    /// Qwen2.5-VL，可给出场景语义理解。
    func analyzeImage(
        imageURL: String? = nil,
        imageBase64: String? = nil,
        prompt: String = "请解析图片中的文字、人物、物体、场景和风险点。",
        includeOCR: Bool = true,
        includeGrounding: Bool = true,
        detectionQueries: [String] = LingShuCloudPerceptionClient.defaultDetectionQueries,
        includeQwenSemantics: Bool = true
    ) async throws -> LingShuCloudPerceptionResult {
        var body: [String: Any] = [
            "prompt": prompt,
            "include_ocr": includeOCR,
            "include_grounding": includeGrounding,
            "detection_queries": detectionQueries,
            "include_qwen_semantics": includeQwenSemantics
        ]
        try attachMedia(&body, urlKey: "image_url", base64Key: "image_base64", url: imageURL, base64: imageBase64)
        return try await invokePerception(route: "swds-vision-fast", body: body)
    }

    /// 音频/听觉理解（swds-realtime-hearing）。
    func analyzeAudio(
        audioURL: String? = nil,
        audioBase64: String? = nil,
        language: String = "auto"
    ) async throws -> LingShuCloudPerceptionResult {
        var body: [String: Any] = [
            "language": language,
            "include_qwen_semantics": false
        ]
        try attachMedia(&body, urlKey: "audio_url", base64Key: "audio_base64", url: audioURL, base64: audioBase64)
        return try await invokePerception(route: "swds-realtime-hearing", body: body)
    }

    /// 视频/深度视觉理解（swds-vision-deep）。
    func analyzeVideo(
        videoURL: String? = nil,
        videoBase64: String? = nil,
        prompt: String = "请按关键帧理解视频内容，输出人物、事件、文字、语音转写和异常风险。",
        sampleIntervalSec: Int = 1,
        maxKeyframes: Int = 8,
        includeOCR: Bool = true,
        includeGrounding: Bool = true,
        detectionQueries: [String] = LingShuCloudPerceptionClient.defaultDetectionQueries,
        includeQwenSemantics: Bool = true
    ) async throws -> LingShuCloudPerceptionResult {
        var body: [String: Any] = [
            "prompt": prompt,
            "sample_interval_sec": sampleIntervalSec,
            "max_keyframes": maxKeyframes,
            "include_ocr": includeOCR,
            "include_grounding": includeGrounding,
            "detection_queries": detectionQueries,
            "include_qwen_semantics": includeQwenSemantics
        ]
        try attachMedia(&body, urlKey: "video_url", base64Key: "video_base64", url: videoURL, base64: videoBase64)
        return try await invokePerception(route: "swds-vision-deep", body: body)
    }

    // MARK: - 解析

    /// 把感知接口的原始 JSON 归一化成统一结果。独立成静态方法以便离线测试。
    static func decodeResult(from data: Data) throws -> LingShuCloudPerceptionResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LingShuCloudPerceptionError.malformedResponse
        }

        var transcript = ""
        if let transcriptObject = object["transcript"] as? [String: Any],
           let text = transcriptObject["text"] as? String {
            transcript = text
        }

        var ocrTexts: [String] = []
        if let ocr = object["ocr"] as? [String: Any],
           let blocks = ocr["blocks"] as? [[String: Any]] {
            ocrTexts = blocks.compactMap { $0["text"] as? String }
        }
        if let keyframes = object["keyframes"] as? [[String: Any]] {
            for frame in keyframes {
                if let frameOCR = frame["ocr"] as? [[String: Any]] {
                    ocrTexts += frameOCR.compactMap { $0["text"] as? String }
                }
            }
        }

        var detectionCount = 0
        if let detections = object["detections"] as? [[String: Any]] {
            detectionCount = detections.count
        }

        var semantics = ""
        if let suggestions = object["semantic_suggestions"] as? [String: Any], !suggestions.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: suggestions, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            semantics = text
        }

        var totalTokens: Int?
        if let usage = object["usage"] as? [String: Any] {
            totalTokens = usage["total_tokens"] as? Int
        }

        return LingShuCloudPerceptionResult(
            success: object["success"] as? Bool ?? false,
            taskType: object["task_type"] as? String ?? "",
            transcript: transcript,
            ocrTexts: ocrTexts,
            detectionCount: detectionCount,
            semanticSuggestions: semantics,
            warnings: (object["warnings"] as? [String]) ?? [],
            totalTokens: totalTokens,
            model: object["model"] as? String ?? ""
        )
    }

    // MARK: - 内部

    private func invokePerception(route: String, body: [String: Any]) async throws -> LingShuCloudPerceptionResult {
        var request = URLRequest(url: perceptionURL(route: route))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyAuthHeaders(&request)

        let data = try await perform(request)
        return try Self.decodeResult(from: data)
    }

    private func perceptionURL(route: String) -> URL {
        baseEndpoint
            .appendingPathComponent("perception", isDirectory: false)
            .appendingPathComponent(route, isDirectory: false)
    }

    private func applyAuthHeaders(_ request: inout URLRequest) {
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Model-Token")
    }

    private func attachMedia(
        _ body: inout [String: Any],
        urlKey: String,
        base64Key: String,
        url: String?,
        base64: String?
    ) throws {
        if let url, !url.isEmpty {
            body[urlKey] = url
        } else if let base64, !base64.isEmpty {
            body[base64Key] = base64
        } else {
            throw LingShuCloudPerceptionError.missingMediaSource
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LingShuCloudPerceptionError.requestFailed(-1, "感知网关返回了非 HTTP 响应。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LingShuCloudPerceptionError.requestFailed(httpResponse.statusCode, String(bodyText.prefix(600)))
        }
        return data
    }
}
