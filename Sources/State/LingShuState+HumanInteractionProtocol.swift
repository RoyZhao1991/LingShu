import Foundation

/// App-facing contract for a human interaction. It resolves execution output into
/// renderable material before the UI is asked to pause a task.
@MainActor
extension LingShuState {
    nonisolated static var interactionMaterialRetryMarker: String {
        "__LINGSHU_INTERACTION_MATERIAL_RETRY__"
    }

    nonisolated static func requiresHardHumanInteractionPresentation(
        _ request: LingShuHumanInteractionRequest
    ) -> Bool {
        // A request in this protocol always pauses a task for a real human action.
        // Keep its surface inside LingShu; a model-provided presentation hint must not
        // bypass the app-native modal or move the user back to a terminal/inline prompt.
        _ = request
        return true
    }

    /// Resolve execution-side references before an interaction crosses into the UI.
    /// The model may identify a hosted job or log, but only the app decides how to read
    /// and render it. This keeps terminals and helper processes out of the user contract.
    func prepareHumanInteractionRequest(
        _ rawRequest: LingShuHumanInteractionRequest
    ) -> LingShuHumanInteractionRequest {
        guard var request = rawRequest.normalized else { return rawRequest }
        guard request.presentationIssue != nil else {
            request.prompt = Self.appNativeHumanInteractionPrompt(request.prompt)
            return request
        }

        if let jobID = request.payload["source_job_id"],
           let snapshot = longCommandRegistry.snapshot(id: jobID) {
            request = LingShuHumanInteractionMaterialExtractor.enriching(
                request,
                sourceText: snapshot.tail,
                sourceLabel: snapshot.label
            )
        }

        if request.presentationIssue != nil,
           let path = request.payload["source_log_path"] ?? request.payload["source_output_path"],
           let text = Self.humanInteractionSourceText(path: path) {
            request = LingShuHumanInteractionMaterialExtractor.enriching(
                request,
                sourceText: text,
                sourceLabel: URL(fileURLWithPath: path).lastPathComponent
            )
        }

        if request.presentationIssue != nil,
           [.qrCode, .externalLogin].contains(request.kind),
           let snapshot = longCommandRegistry.snapshots().first(where: {
               guard $0.status == .running else { return false }
               let enriched = LingShuHumanInteractionMaterialExtractor.enriching(request, sourceText: $0.tail)
               return enriched.presentationIssue == nil
           }) {
            request.payload["source_job_id"] = snapshot.id
            request.payload["source_log_path"] = snapshot.logPath
            request = LingShuHumanInteractionMaterialExtractor.enriching(
                request,
                sourceText: snapshot.tail,
                sourceLabel: snapshot.label
            )
        }

        request.prompt = Self.appNativeHumanInteractionPrompt(request.prompt)
        return request.normalized ?? request
    }

    private nonisolated static func humanInteractionSourceText(path: String) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return nil }
        return String(data: Data(data.suffix(64_000)), encoding: .utf8)
    }

    private nonisolated static func appNativeHumanInteractionPrompt(_ raw: String) -> String {
        var text = raw
        let replacements = [
            "终端窗口中显示的": "下方展示的",
            "终端窗口里显示的": "下方展示的",
            "终端中显示的": "下方展示的",
            "终端里显示的": "下方展示的",
            "终端窗口里的": "下方的",
            "终端里的": "下方的"
        ]
        for (source, target) in replacements {
            text = text.replacingOccurrences(of: source, with: target)
        }
        let englishReplacements: [(String, String)] = [
            (#"(?i)the QR code (?:shown|displayed) in the terminal(?: window)?"#, "the QR code below"),
            (#"(?i)the code (?:shown|displayed) in the terminal(?: window)?"#, "the code below")
        ]
        for (pattern, replacement) in englishReplacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: replacement
            )
        }
        return text
    }

    nonisolated static func requestHumanInteractionTool(
        prepare: @escaping @Sendable (LingShuHumanInteractionRequest) async -> LingShuHumanInteractionRequest = { $0 }
    ) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "request_human_interaction",
            description: "Pause the exact task session for human participation. Every action must be fully completable inside the LingShu app: include the actual QR payload/image, login URL, visible code/text, file picker mode, form fields, or choices as materials. A terminal or helper process is never a user interface. If material comes from start_long_command, pass source_job_id or source_log_path so the host can extract it. Missing required material is rejected instead of showing an empty interaction. LingShu resumes the same session after the user responds. OAuth/auth markers remain a separate protocol.",
            parametersJSON: #"""
            {
              "type": "object",
              "properties": {
                "id": {"type": "string", "description": "Optional stable interaction id"},
                "kind": {"type": "string", "enum": ["question", "choice", "form", "qr_code", "external_login", "physical_action", "file_selection", "confirmation", "custom"]},
                "title": {"type": "string", "description": "Short user-facing title"},
                "prompt": {"type": "string", "description": "Exact action the user must complete"},
                "payload": {"type": "object", "description": "Compatibility display data such as image_path, qr_content, qr_text, login_url, form_json, selection, source_job_id, or source_log_path. Encode values as strings.", "additionalProperties": {"type": "string"}},
                "source_job_id": {"type": "string", "description": "Optional start_long_command job containing the material to show"},
                "source_log_path": {"type": "string", "description": "Optional local output/log file containing the material to show"},
                "materials": {
                  "type": "array",
                  "description": "Typed content rendered directly in LingShu. Use qr_code value for content that LingShu should turn into a scannable QR image.",
                  "items": {
                    "type": "object",
                    "properties": {
                      "id": {"type": "string"},
                      "kind": {"type": "string", "enum": ["image", "qr_code", "text", "code", "url", "file"]},
                      "title": {"type": "string"},
                      "value": {"type": "string"},
                      "mime_type": {"type": "string"}
                    },
                    "required": ["kind", "value"]
                  }
                },
                "options": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "id": {"type": "string"},
                      "label": {"type": "string"},
                      "detail": {"type": "string"},
                      "value": {"type": "string"}
                    },
                    "required": ["label"]
                  }
                },
                "completion_probe": {
                  "type": "object",
                  "properties": {
                    "kind": {"type": "string", "enum": ["manual", "http_status", "file_exists"]},
                    "target": {"type": "string"},
                    "expected_status": {"type": "integer"},
                    "interval_seconds": {"type": "number"},
                    "timeout_seconds": {"type": "number"}
                  },
                  "required": ["kind"]
                }
              },
              "required": ["kind", "prompt"]
            }
            """#
        ) { argumentsJSON in
            guard let data = argumentsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var request = LingShuHumanInteractionRequest.parse(object) else {
                return "request_human_interaction 参数无效：必须提供合法 kind 和非空 prompt。"
            }
            if request.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                request.source = "agent"
            }
            request = await prepare(request)
            guard request.presentationIssue == nil else {
                return "INTERACTION_NOT_READY: \(request.presentationIssue ?? "The app cannot present this interaction.") Provide the real user-visible material or reference its hosted source_job_id/source_log_path, then call request_human_interaction again. Do not tell the user to use a terminal."
            }
            return LingShuWorkflowControlEnvelope(event: .requiresHumanInteraction(request)).encodedPrompt
        }
    }
}
