import SwiftUI
import AppKit

/// Generic human-in-the-loop presentation. Authorization cards are deliberately
/// separate and only appear from the structured OAuth/auth protocol.
struct LingShuHumanInteractionCard: View {
    @ObservedObject var state: LingShuState
    let request: LingShuHumanInteractionRequest
    let onSubmit: (_ answer: String, _ displayAnswer: String) -> Void
    @Environment(\.openURL) private var openURL

    init(
        state: LingShuState,
        request: LingShuHumanInteractionRequest,
        onSubmit: @escaping (_ answer: String, _ displayAnswer: String) -> Void = { _, _ in }
    ) {
        self.state = state
        self.request = request
        self.onSubmit = onSubmit
    }

    private var imagePath: String? {
        ["image_path", "qr_path", "file_path"].compactMap { request.payload[$0] }.first
    }

    private var actionURL: URL? {
        ["verification_url", "login_url", "url"]
            .compactMap { request.payload[$0] }
            .compactMap(URL.init(string:))
            .first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.lingHolo)
                Text(request.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.lingFg)
            }

            if request.title != request.prompt {
                Text(request.prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.lingFg.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let imagePath,
               let image = NSImage(contentsOfFile: NSString(string: imagePath).expandingTildeInPath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let actionURL {
                Button {
                    openURL(actionURL)
                } label: {
                    Label(actionLabel, systemImage: "arrow.up.right.square")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if request.kind == .fileSelection {
                Button(action: chooseFile) {
                    Label(state.loc("选择文件", "Choose File"), systemImage: "folder.badge.plus")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if request.completionProbe?.kind != .manual,
               request.completionProbe != nil {
                Label(state.loc("完成后会自动检测并继续", "LingShu will detect completion and continue"), systemImage: "waveform.path.ecg")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.lingFg.opacity(0.55))
            }
        }
        .padding(12)
        .background(Color.lingHolo.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.22), lineWidth: 1)
        }
    }

    private var iconName: String {
        switch request.kind {
        case .qrCode: "qrcode.viewfinder"
        case .externalLogin: "person.badge.key"
        case .physicalAction: "hand.tap"
        case .fileSelection: "folder"
        case .form: "list.bullet.clipboard"
        case .choice, .confirmation: "checkmark.circle"
        case .question, .custom: "person.crop.circle.badge.questionmark"
        }
    }

    private var actionLabel: String {
        switch request.kind {
        case .externalLogin: state.loc("打开登录页面", "Open Login Page")
        case .qrCode: state.loc("打开扫码页面", "Open QR Page")
        default: state.loc("打开", "Open")
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        let directoryOnly = request.payload["selection"] == "directory"
            || request.payload["directory_only"] == "true"
        panel.canChooseFiles = !directoryOnly
        panel.canChooseDirectories = directoryOnly || request.payload["allow_directories"] == "true"
        panel.allowsMultipleSelection = request.payload["allows_multiple"] == "true"
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let paths = panel.urls.map(\.path)
            let names = panel.urls.map(\.lastPathComponent)
            onSubmit(paths.joined(separator: "\n"), names.joined(separator: "、"))
        }
    }
}
