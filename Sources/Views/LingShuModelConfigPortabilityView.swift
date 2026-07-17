import SwiftUI
import AppKit

/// 「大模型配置加密导入/导出」UI 口子(挂在模型通道页头下)。
/// 导出:口令(两遍)→ 选保存位置 → 把当前脑/通道/密钥口令加密成一个文件。
/// 导入:选文件 → 口令 → 一键恢复并立即可用。没口令谁也解不开(可安全分享/开源)。
struct LingShuModelConfigPortabilityBar: View {
    @ObservedObject var state: LingShuState
    @State private var sheet: Sheet?
    @State private var status: String = ""
    @State private var statusOK: Bool = true

    enum Sheet: Identifiable {
        case export
        case importing(URL)
        var id: String { switch self { case .export: "export"; case .importing(let u): "import:\(u.path)" } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                actionButton(state.loc("导出加密配置", "Export Encrypted Config"), icon: "lock.doc") { sheet = .export }
                actionButton(state.loc("导入配置", "Import Config"), icon: "square.and.arrow.down") { beginImport() }
                Spacer()
            }
            if !status.isEmpty {
                Text(state.localizedRuntimeText(status, fallback: statusOK ? state.loc("配置已更新", "Configuration updated") : state.loc("配置操作失败", "Configuration operation failed")))
                    .font(.system(size: 11.5))
                    .foregroundStyle(statusOK ? Color.green.opacity(0.9) : Color.orange.opacity(0.95))
            }
            Text(state.loc("把当前接入的脑/通道/各密钥用口令加密成一个文件;换台机器或给别人,用同一口令一键导入即用。没口令谁也解不开——可安全分享 / 开源。", "Encrypt the configured brain, channels, and credentials into one file. Import it on another Mac with the same passphrase; without the passphrase, the secrets cannot be decrypted."))
                .font(.system(size: 11))
                .foregroundStyle(Color.lingFg.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(item: $sheet) { s in
            LingShuPassphraseSheet(mode: s) { passphrase in
                handle(sheet: s, passphrase: passphrase)
            } onCancel: { sheet = nil }
            .frame(minWidth: 460, minHeight: 260)
        }
    }

    private func actionButton(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.lingVoid)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func beginImport() {
        let panel = NSOpenPanel()
        panel.title = state.loc("选择灵枢加密配置文件", "Choose an Encrypted Nous Configuration")
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            sheet = .importing(url)
        }
    }

    private func handle(sheet s: Sheet, passphrase: String) {
        switch s {
        case .export:
            let panel = NSSavePanel()
            panel.title = state.loc("保存加密配置", "Save Encrypted Configuration")
            panel.nameFieldStringValue = state.loc("灵枢模型配置.lingshucfg", "Nous-model-config.lingshucfg")
            sheet = nil
            guard panel.runModal() == .OK, let url = panel.url else { return }
            switch state.exportModelConfig(passphrase: passphrase, to: url) {
            case .success(let r):
                statusOK = true
                status = state.loc("✅ 已加密导出(\(r.summary))→ \(url.lastPathComponent)。用同一口令即可在别处一键导入。", "✅ Encrypted export complete (\(r.summary)) → \(url.lastPathComponent). Use the same passphrase to import it elsewhere.")
            case .failure(let e):
                statusOK = false
                status = state.loc("导出失败:", "Export failed: ") + localizedError(e)
            }
        case .importing(let url):
            sheet = nil
            switch state.importModelConfig(passphrase: passphrase, from: url) {
            case .success(let b):
                statusOK = true
                status = state.loc("✅ 已导入并启用:脑=\(b.provider)/\(b.model) · 通道 \(b.channels.count) 个 · 密钥 \(b.credentials.count) 条。下一回合即用新配置。", "✅ Imported and enabled: brain \(b.provider)/\(b.model) · \(b.channels.count) channels · \(b.credentials.count) credentials. The new configuration applies next turn.")
            case .failure(let e):
                statusOK = false
                status = state.loc("导入失败:", "Import failed: ") + localizedError(e)
            }
        }
    }

    private func localizedError(_ error: Error) -> String {
        if let error = error as? LingShuModelConfigPortability.PortError {
            switch error {
            case .weakPassphrase: return state.loc("口令太短（至少 \(LingShuModelConfigPortability.minPassphraseLength) 位）", "The passphrase is too short (minimum \(LingShuModelConfigPortability.minPassphraseLength) characters).")
            case .encodeFailed: return state.loc("配置序列化失败", "The configuration could not be encoded.")
            case .badFile: return state.loc("不是合法的灵枢配置文件", "This is not a valid Nous configuration file.")
            case .wrongPassphraseOrCorrupt: return state.loc("口令错误或文件已损坏", "The passphrase is incorrect or the file is damaged.")
            }
        }
        return state.language == .english ? "Unexpected configuration error." : error.localizedDescription
    }
}

/// 口令输入弹窗:导出要两遍一致 + 最短长度;导入只要一遍。
private struct LingShuPassphraseSheet: View {
    let mode: LingShuModelConfigPortabilityBar.Sheet
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var pass = ""
    @State private var confirm = ""

    private var isExport: Bool { if case .export = mode { return true }; return false }
    private var tooShort: Bool { pass.count < LingShuModelConfigPortability.minPassphraseLength }
    private var mismatch: Bool { isExport && pass != confirm }
    private var canConfirm: Bool { !tooShort && !mismatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isExport
                 ? LingShuLanguagePreferenceStore.localized("设置导出口令", "Set Export Passphrase")
                 : LingShuLanguagePreferenceStore.localized("输入导入口令", "Enter Import Passphrase"))
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.lingFg)
            Text(isExport
                 ? LingShuLanguagePreferenceStore.localized("这个口令保护导出的密钥;导入时要用同一个。请妥善保管——丢了就解不开。", "This passphrase protects exported credentials and is required for import. Store it safely; it cannot be recovered.")
                 : LingShuLanguagePreferenceStore.localized("输入导出时设置的口令以解密恢复配置。", "Enter the passphrase used during export to decrypt and restore the configuration."))
                .font(.system(size: 11.5)).foregroundStyle(Color.lingFg.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            SecureField(LingShuLanguagePreferenceStore.localized("口令(至少 \(LingShuModelConfigPortability.minPassphraseLength) 位)", "Passphrase (at least \(LingShuModelConfigPortability.minPassphraseLength) characters)"), text: $pass)
                .textFieldStyle(.roundedBorder)
            if isExport {
                SecureField(LingShuLanguagePreferenceStore.localized("再输一遍", "Enter it again"), text: $confirm)
                    .textFieldStyle(.roundedBorder)
            }
            if tooShort, !pass.isEmpty {
                Text(LingShuLanguagePreferenceStore.localized("口令至少 \(LingShuModelConfigPortability.minPassphraseLength) 位", "Passphrase must contain at least \(LingShuModelConfigPortability.minPassphraseLength) characters")).font(.system(size: 11)).foregroundStyle(.orange)
            } else if mismatch, !confirm.isEmpty {
                Text(LingShuLanguagePreferenceStore.localized("两次口令不一致", "Passphrases do not match")).font(.system(size: 11)).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(LingShuLanguagePreferenceStore.localized("取消", "Cancel"), action: onCancel).buttonStyle(.plain).foregroundStyle(Color.lingFg.opacity(0.7))
                Button(isExport ? LingShuLanguagePreferenceStore.localized("导出", "Export") : LingShuLanguagePreferenceStore.localized("导入", "Import")) { onConfirm(pass) }
                    .buttonStyle(.plain)
                    .foregroundStyle(canConfirm ? Color.lingVoid : Color.lingFg.opacity(0.3))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(canConfirm ? Color.lingHolo : Color.lingFg.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .disabled(!canConfirm)
            }
        }
        .padding(22)
        .background(Color.lingVoid)
    }
}
