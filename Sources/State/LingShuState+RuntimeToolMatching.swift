import Foundation

struct LingShuRuntimeToolDescriptor: Sendable, Equatable {
    var name: String
    var description: String
    var source: String
}

@MainActor
extension LingShuState {
    /// Runtime tool facts used by the cognition/preflight layer. This is intentionally generic:
    /// if a tool is registered in the current runtime, model-side capability guessing must not
    /// override that fact with a speculative "missing auth/tool" conclusion.
    func runtimeToolDescriptorsForCapabilityMatching() -> [LingShuRuntimeToolDescriptor] {
        var descriptors: [LingShuRuntimeToolDescriptor] = []

        descriptors.append(contentsOf: LingShuFunctionCallingCatalog.builtin.map {
            LingShuRuntimeToolDescriptor(name: $0.name, description: $0.description, source: "builtin")
        })
        descriptors.append(contentsOf: connectorRegistry.discoveredTools.map {
            LingShuRuntimeToolDescriptor(name: $0.name, description: $0.description, source: "mcp")
        })

        let directTools =
            localKnowledgeTools()
            + previewTools()
            + browserTools()
            + computerControlTools()
            + backgroundWatchTools()
            + scheduledTaskTools()
            + [listCapabilitiesTool()]

        descriptors.append(contentsOf: directTools.map {
            LingShuRuntimeToolDescriptor(name: $0.name, description: $0.description, source: "runtime")
        })

        var seen = Set<String>()
        return descriptors.filter { item in
            let key = item.name.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    func explicitlyMentionedRuntimeTools(in contextText: String) -> [LingShuRuntimeToolDescriptor] {
        let lower = contextText.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return runtimeToolDescriptorsForCapabilityMatching().filter { tool in
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name.count >= 3 else { return false }
            return lower.contains(name)
        }
    }

    /// Returns a registered tool explicitly named by the user and semantically overlapping with
    /// the preflight item being judged. This avoids domain-specific allowlists while preventing
    /// a generic tool such as `run_command` from satisfying an unrelated external-service gap.
    func explicitlySelectedRuntimeTool(covers text: String, in contextText: String) -> LingShuRuntimeToolDescriptor? {
        let mentioned = explicitlyMentionedRuntimeTools(in: contextText)
        guard !mentioned.isEmpty else { return nil }
        let lower = text.lowercased()
        let targetTokens = Self.capabilityMatchTokens(text)
        for tool in mentioned {
            let name = tool.name.lowercased()
            if lower.contains(name) { return tool }
            let toolTokens = Self.capabilityMatchTokens("\(tool.name) \(tool.description)")
            if !targetTokens.isEmpty, !toolTokens.isDisjoint(with: targetTokens) {
                return tool
            }
        }
        return nil
    }

    func runtimeToolCapabilityVerb(_ tool: LingShuRuntimeToolDescriptor) -> LingShuCapabilityVerb? {
        if tool.source != "mcp", Self.runtimeToolLooksLocalOrKernel(tool) {
            return .localFileScan
        }
        return LingShuCapabilityVerb.infer(
            id: "tool:\(tool.name)",
            description: tool.description,
            source: tool.source
        )
    }

    nonisolated static func runtimeToolLooksLocalOrKernel(_ tool: LingShuRuntimeToolDescriptor) -> Bool {
        let text = "\(tool.name) \(tool.description) \(tool.source)".lowercased()
        let localSignals = [
            "本机", "本地", "零上传", "on-device", "local",
            "read_file", "list_directory", "search_text",
            "recall_", "index_", "读取", "检索", "索引"
        ]
        return localSignals.contains { text.contains($0.lowercased()) }
    }

    nonisolated static func capabilityMatchTokens(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let stopwords: Set<String> = [
            "工具", "用户", "主人", "调用", "需要", "授权", "凭据", "登录", "服务",
            "能力", "系统", "数据", "提供", "完成", "外部", "本地", "本机", "索引",
            "工作", "目录", "文件", "结果", "任务", "执行"
        ]
        var tokens = Set<String>()
        var ascii = ""
        var cjkScalars: [UnicodeScalar] = []

        func flushASCII() {
            guard ascii.count >= 3 else {
                ascii.removeAll()
                return
            }
            if !stopwords.contains(ascii) { tokens.insert(ascii) }
            ascii.removeAll()
        }

        func flushCJK() {
            let chars = cjkScalars.map(String.init)
            guard chars.count >= 2 else {
                cjkScalars.removeAll()
                return
            }
            if chars.count <= 4 {
                let word = chars.joined()
                if !stopwords.contains(word) { tokens.insert(word) }
            }
            for i in 0..<(chars.count - 1) {
                let pair = chars[i] + chars[i + 1]
                if !stopwords.contains(pair) { tokens.insert(pair) }
            }
            cjkScalars.removeAll()
        }

        for scalar in lower.unicodeScalars {
            if isASCIIWordScalar(scalar) {
                flushCJK()
                ascii.unicodeScalars.append(scalar)
            } else if isCJKScalar(scalar) {
                flushASCII()
                cjkScalars.append(scalar)
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()
        return tokens
    }

    nonisolated static func isASCIIWordScalar(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) ||
        (scalar.value >= 97 && scalar.value <= 122) ||
        scalar.value == 95
    }

    nonisolated static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
        (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) ||
        (scalar.value >= 0x20000 && scalar.value <= 0x2A6DF)
    }
}
