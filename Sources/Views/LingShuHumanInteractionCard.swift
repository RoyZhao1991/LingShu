import SwiftUI
import AppKit
import CoreImage

/// Generic human-in-the-loop presentation. Authorization cards are deliberately
/// separate and only appear from the structured OAuth/auth protocol.
struct LingShuHumanInteractionCard: View {
    @ObservedObject var state: LingShuState
    let request: LingShuHumanInteractionRequest
    let showsReopenAction: Bool
    let onSubmit: (_ answer: String, _ displayAnswer: String) -> Void
    @Environment(\.openURL) private var openURL

    init(
        state: LingShuState,
        request: LingShuHumanInteractionRequest,
        showsReopenAction: Bool = true,
        onSubmit: @escaping (_ answer: String, _ displayAnswer: String) -> Void = { _, _ in }
    ) {
        self.state = state
        self.request = request
        self.showsReopenAction = showsReopenAction
        self.onSubmit = onSubmit
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

            ForEach(request.displayMaterials) { material in
                materialView(material)
            }

            if request.presentationIssue != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Label(state.loc("交互内容尚未就绪", "Interaction content is not ready"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(state.loc(
                        "执行端还没有提供完成这一步所需的真实内容。灵枢不会让你去寻找隐藏的终端或盲目确认。",
                        "The execution side has not provided the real content required for this step. Nous will not send you to a hidden terminal or ask for a blind confirmation."
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.lingFg.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if request.kind == .fileSelection {
                Button(action: chooseFile) {
                    Label(state.loc("选择文件", "Choose File"), systemImage: "folder.badge.plus")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if showsReopenAction,
               LingShuState.requiresHardHumanInteractionPresentation(request),
               state.isHumanInteractionPending(request) {
                Button {
                    state.presentHardHumanInteraction(request)
                } label: {
                    Label(state.loc("打开交互窗口", "Open Interaction"), systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if request.completionProbe?.kind != .manual,
               request.completionProbe != nil {
                Label(state.loc("完成后会自动检测并继续", "Nous will detect completion and continue"), systemImage: "waveform.path.ecg")
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

    @ViewBuilder
    private func materialView(_ material: LingShuHumanInteractionRequest.Material) -> some View {
        switch material.kind {
        case .image:
            if let image = Self.image(from: material) {
                imageView(image, title: material.title)
            } else {
                unavailableMaterial(material)
            }
        case .qrCode:
            if let image = Self.qrImage(from: material.value) {
                imageView(image, title: material.title.isEmpty ? state.loc("扫码", "Scan") : material.title)
            } else {
                unavailableMaterial(material)
            }
        case .text:
            materialHeading(material)
            Text(material.value)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.lingFg.opacity(0.82))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code:
            materialHeading(material)
            ScrollView([.horizontal, .vertical]) {
                Text(material.value)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: 340, minHeight: 90, maxHeight: 300)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .url:
            if let url = URL(string: material.value) {
                Button { openURL(url) } label: {
                    Label(material.title.isEmpty ? actionLabel : material.title, systemImage: "arrow.up.right.square")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                unavailableMaterial(material)
            }
        case .file:
            let expanded = NSString(string: material.value).expandingTildeInPath
            HStack(spacing: 8) {
                Label(material.title.isEmpty ? URL(fileURLWithPath: expanded).lastPathComponent : material.title,
                      systemImage: "doc")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Button(state.loc("打开", "Open")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(state.loc("在 Finder 中显示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func materialHeading(_ material: LingShuHumanInteractionRequest.Material) -> some View {
        if !material.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(material.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(0.62))
        }
    }

    private func imageView(_ image: NSImage, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.lingFg.opacity(0.62))
            }
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 280)
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func unavailableMaterial(_ material: LingShuHumanInteractionRequest.Material) -> some View {
        Label(
            state.loc("无法读取交互内容：\(material.title)", "Cannot read interaction content: \(material.title)"),
            systemImage: "exclamationmark.triangle"
        )
        .font(.system(size: 11.5))
        .foregroundStyle(.orange)
    }

    private static func image(from material: LingShuHumanInteractionRequest.Material) -> NSImage? {
        let value = material.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("data:"), let comma = value.firstIndex(of: ",") {
            return NSImage(data: Data(base64Encoded: String(value[value.index(after: comma)...])) ?? Data())
        }
        let path: String
        if let url = URL(string: value), url.isFileURL { path = url.path }
        else { path = NSString(string: value).expandingTildeInPath }
        if let image = NSImage(contentsOfFile: path) { return image }
        guard let data = Data(base64Encoded: value) else { return nil }
        return NSImage(data: data)
    }

    private static func qrImage(from value: String) -> NSImage? {
        guard let data = value.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
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

/// App-modal presentation for hard human steps. Closing the terminal or a helper
/// process cannot accidentally satisfy or cancel this interaction.
struct LingShuHardHumanInteractionView: View {
    @ObservedObject var state: LingShuState
    let pending: LingShuPendingHardHumanInteraction
    @State private var responseText = ""

    private var request: LingShuHumanInteractionRequest { pending.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Color.lingHolo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.loc("需要你完成一步", "Your Action Is Required"))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.lingFg)
                    Text(state.loc("任务已安全暂停，完成后会从原位置继续。", "The task is safely paused and will resume from the same point."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.lingFg.opacity(0.62))
                }
                Spacer(minLength: 0)
            }

            LingShuHumanInteractionCard(
                state: state,
                request: request,
                showsReopenAction: false
            ) { answer, displayAnswer in
                state.completeHardHumanInteraction(pending, answer: answer, displayAnswer: displayAnswer)
            }

            if request.presentationIssue != nil {
                Button {
                    state.retryHardHumanInteractionMaterial(pending)
                } label: {
                    Label(state.loc("让灵枢重新获取交互内容", "Ask Nous to retrieve the interaction content"),
                          systemImage: "arrow.clockwise")
                        .font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
            } else if let form = request.confirmForm {
                LingShuFormCard(form: form, resolved: nil) { answers in
                    state.completeHardHumanInteraction(
                        pending,
                        answer: form.formatAnswers(answers),
                        displayAnswer: state.loc("表单已提交", "Form submitted")
                    )
                }
            } else if !request.options.isEmpty {
                VStack(spacing: 8) {
                    ForEach(request.options) { option in
                        Button {
                            state.completeHardHumanInteraction(
                                pending,
                                answer: option.value,
                                displayAnswer: option.label
                            )
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).fontWeight(.semibold)
                                    if !option.detail.isEmpty {
                                        Text(option.detail)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Color.lingFg.opacity(0.58))
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if request.kind == .question || expectsTextResponse {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $responseText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.lingFg)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 86, maxHeight: 150)
                        .background(Color.lingFg.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.lingFg.opacity(0.12), lineWidth: 1)
                        }
                    Button {
                        let value = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                        state.completeHardHumanInteraction(pending, answer: value, displayAnswer: value)
                    } label: {
                        Label(state.loc("提交并继续", "Submit and Continue"), systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if request.kind == .confirmation {
                HStack(spacing: 10) {
                    Button {
                        state.completeHardHumanInteraction(
                            pending,
                            answer: "confirmed",
                            displayAnswer: state.loc("已确认", "Confirmed")
                        )
                    } label: {
                        Label(state.loc("确认并继续", "Confirm and Continue"), systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        state.completeHardHumanInteraction(
                            pending,
                            answer: "declined",
                            displayAnswer: state.loc("未确认", "Declined")
                        )
                    } label: {
                        Label(state.loc("不确认", "Decline"), systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else if request.kind != .fileSelection {
                Button {
                    state.completeHardHumanInteraction(
                        pending,
                        answer: "已完成",
                        displayAnswer: state.loc("已完成，继续", "Completed, Continue")
                    )
                } label: {
                    Label(state.loc("已完成，继续", "Completed, Continue"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Button {
                state.deferHardHumanInteraction()
            } label: {
                Label(state.loc("稍后处理", "Handle Later"), systemImage: "clock")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.lingFg.opacity(0.68))
            .help(state.loc("任务会保持暂停，可从聊天中的交互卡片重新打开。", "The task stays paused; reopen it from the interaction card in chat."))
        }
        .padding(24)
        .frame(width: 600)
        .background(Color.lingVoid)
    }

    private var expectsTextResponse: Bool {
        request.kind == .custom
            && request.payload["response_mode"]?.lowercased() != "completion"
            && request.displayMaterials.isEmpty
    }
}
