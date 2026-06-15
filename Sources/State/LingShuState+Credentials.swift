import Foundation

/// 凭据四肢(计划 §5,方案 B:大脑只见 key、不见明文)。
///
/// - `remember_credential(key, value)`:把秘密存进现有 AES-GCM 加密库(`credentialStore`,本机绑定),**绝不回显**。
/// - `list_credentials()`:只列已存的 key 名,**永不返回明文值**。
/// - 大脑用凭据时**只引用 key**:在 run_command / fetch_url 里写占位符 `{{cred:KEY}}`,由壳在**执行层**按 key
///   从加密库取出真值替换后再执行——明文**不进模型上下文、不进任务记录**(记录保留占位符,输出里若回显了秘密会被打码)。
@MainActor
extension LingShuState {
    /// 用户凭据在加密库里的命名空间前缀(与模型/网关凭据隔离)。
    nonisolated static let userCredentialPrefix = "usercred-"
    /// 占位符正则:{{cred:KEY}},KEY 由字母数字 . _ - 组成。
    nonisolated static let credentialPlaceholderPattern = "\\{\\{cred:([A-Za-z0-9._-]+)\\}\\}"

    func rememberCredentialTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "remember_credential",
            description: "安全保存一条凭据/密钥(token、API key、密码等)到本机加密库,只记 key 名、**绝不回显明文**。之后你在 run_command / fetch_url 里用占位符 `{{cred:KEY}}` 引用它,壳会在执行时替换成真值——你自己永远看不到明文。用户给你密钥时用它存,别把明文写进文件或回复。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\",\"description\":\"凭据的标识名(如 github、openai、db_password),后续用 {{cred:这个名字}} 引用\"},\"value\":{\"type\":\"string\",\"description\":\"凭据明文值(只用于保存,不会回显)\"}},\"required\":[\"key\",\"value\"]}"
        ) { [weak self] argumentsJSON in
            let key = (Self.jsonField(argumentsJSON, "key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (Self.jsonField(argumentsJSON, "value") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return "保存失败:key 和 value 都不能为空。" }
            return await MainActor.run { [weak self] in
                guard let self else { return "执行环境不可用。" }
                let safeKey = Self.normalizeCredentialKey(key)
                self.credentialStore.setAPIKey(value, forProvider: Self.userCredentialPrefix + safeKey)
                self.logEvent("凭据已保存(加密落盘,未回显):\(safeKey)")
                return "已安全保存凭据「\(safeKey)」(加密落盘,我看不到也不会回显明文)。引用它时在命令/URL 里写 {{cred:\(safeKey)}}。"
            }
        }
    }

    func listCredentialsTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "list_credentials",
            description: "列出已保存的凭据 **key 名**(不含任何明文值)。想知道有哪些可用凭据、该用哪个 {{cred:KEY}} 时调它。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            await MainActor.run { [weak self] in
                guard let self else { return "执行环境不可用。" }
                let keys = self.credentialStore.providerIDs()
                    .filter { $0.hasPrefix(Self.userCredentialPrefix) }
                    .map { String($0.dropFirst(Self.userCredentialPrefix.count)) }
                guard !keys.isEmpty else { return "当前没有已保存的凭据。需要的话先用 remember_credential 让用户给你存。" }
                return "已保存的凭据 key(用 {{cred:KEY}} 引用,无明文):\n" + keys.map { "- \($0)" }.joined(separator: "\n")
            }
        }
    }

    /// 把字符串里的 `{{cred:KEY}}` 占位符替换成加密库里的真值;返回(替换后文本, 用到的明文集合)。
    /// 明文集合供执行后给输出打码(防命令回显泄露)。找不到对应凭据的占位符原样保留。
    func resolveCredentialPlaceholders(in text: String) -> (resolved: String, secrets: [String]) {
        guard text.contains("{{cred:"),
              let re = try? NSRegularExpression(pattern: Self.credentialPlaceholderPattern) else {
            return (text, [])
        }
        let nsText = text as NSString
        var resolved = text
        var secrets: [String] = []
        let matches = re.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        // 从后往前替换,避免 range 偏移。
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let key = nsText.substring(with: match.range(at: 1))
            guard let value = credentialStore.apiKey(forProvider: Self.userCredentialPrefix + Self.normalizeCredentialKey(key)),
                  !value.isEmpty else { continue }
            let placeholder = nsText.substring(with: match.range)
            resolved = resolved.replacingOccurrences(of: placeholder, with: value)
            if !secrets.contains(value) { secrets.append(value) }
        }
        return (resolved, secrets)
    }

    /// 把输出里出现的明文凭据打码(执行后用,防命令把 token 回显进任务记录/模型上下文)。
    nonisolated static func redactSecrets(_ text: String, secrets: [String]) -> String {
        guard !secrets.isEmpty else { return text }
        var out = text
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: "***")
        }
        return out
    }

    /// 规范化 key 名(小写、去空白),让 {{cred:GitHub}} 与存的 github 命中同一条。
    nonisolated static func normalizeCredentialKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
