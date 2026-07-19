import SwiftUI

struct LingShuBrainSetupView: View {
    @ObservedObject var state: LingShuState

    @State private var route: LingShuBrainSetupRoute = .openAI
    @State private var token = ""
    @State private var selectedModel = LingShuBrainSetupRoute.openAI.defaultModel
    @State private var customEndpoint = ""
    @State private var customModel = ""
    @State private var isConnecting = false
    @State private var validationMessage = ""

    private let routeColumns = [
        GridItem(.flexible(minimum: 150), spacing: 10),
        GridItem(.flexible(minimum: 150), spacing: 10),
        GridItem(.flexible(minimum: 150), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            routePicker
            configurationForm
            Spacer(minLength: 4)
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.lingVoid)
        .onAppear {
            LingShuCleanUserSmokeProbe.recordBrainSetupPresented()
            if state.modelProvider == "Anthropic Claude" {
                route = .claude
                selectedModel = LingShuBrainSetupRoute.claude.defaultModel
            } else if state.modelProvider == "OpenAI" {
                route = .openAI
                selectedModel = LingShuBrainSetupRoute.openAI.defaultModel
            } else if state.modelProvider == "DeepSeek" {
                route = .deepSeek
                selectedModel = LingShuBrainSetupRoute.deepSeek.defaultModel
            } else if state.modelProvider == "MiniMax 官方" {
                route = .minimax
                selectedModel = LingShuBrainSetupRoute.minimax.defaultModel
            }
            validationMessage = state.brainSetupPhase.reason
        }
        .onChange(of: route) { _, newRoute in
            selectedModel = newRoute.defaultModel
            validationMessage = ""
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: "brain.head.profile.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.lingHolo)
                .frame(width: 46, height: 46)
                .background(Color.lingHolo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(state.loc("连接灵枢主脑", "Connect the Nous Brain"))
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color.lingFg)
                Text(state.loc(
                    "检测到当前没有可用的主脑通道。选择服务并完成一次连接验证。",
                    "No working brain channel was found. Choose a provider and verify the connection."
                ))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.55))
            }
        }
    }

    private var routePicker: some View {
        LazyVGrid(columns: routeColumns, spacing: 10) {
            ForEach(LingShuBrainSetupRoute.allCases) { item in
                Button {
                    route = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.loc(item.title, item.englishTitle)).font(.system(size: 13, weight: .bold))
                            Text(state.loc(item.subtitle, item.englishSubtitle)).font(.system(size: 9.5, weight: .medium)).opacity(0.65)
                        }
                        Spacer(minLength: 0)
                        if route == item {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 14, weight: .bold))
                        }
                    }
                    .foregroundStyle(route == item ? Color.lingVoid : Color.lingFg.opacity(0.75))
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(
                        route == item ? Color.lingHolo : Color.lingFg.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            if route == .custom {
                fieldLabel(state.loc("接口地址", "Endpoint"))
                TextField("https://your-gateway.example.com/v1", text: $customEndpoint)
                    .textFieldStyle(.roundedBorder)
                fieldLabel(state.loc("模型名称", "Model name"))
                TextField(state.loc("例如 model-name", "For example, model-name"), text: $customModel)
                    .textFieldStyle(.roundedBorder)
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.loc("已选择 \(route.subtitle)", "Selected: \(route.englishSubtitle)"))
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.lingFg)
                        Text(state.loc("接口地址已预设，无需填写", "The endpoint is preset."))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.lingFg.opacity(0.45))
                    }
                    Spacer()
                    if route.modelOptions.count > 1 {
                        Picker(state.loc("模型", "Model"), selection: $selectedModel) {
                            ForEach(route.modelOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: 250)
                    }
                }
                .padding(12)
                .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            fieldLabel(state.loc("访问 Token", "Access token"))
            SecureField(state.loc("粘贴 Token", "Paste token"), text: $token)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text(state.loc("Token 仅保存在本机加密凭据库中", "The token is stored only in the local encrypted credential store."))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.lingFg.opacity(0.43))

            if !validationMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.orange)
                    Text(validationMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.lingFg.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(isConnecting
                 ? state.loc("正在向模型发送连接校验…", "Verifying the model connection…")
                 : state.loc("验证成功后将自动进入灵枢", "Nous opens automatically after verification"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.45))
            Spacer()
            Button {
                connect()
            } label: {
                HStack(spacing: 7) {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    Text(isConnecting
                         ? state.loc("正在验证", "Verifying")
                         : state.loc("验证并启用", "Verify and Enable"))
                }
                .font(.system(size: 12.5, weight: .bold))
                .padding(.horizontal, 17)
                .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.lingHolo)
            .disabled(isConnecting || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.lingFg.opacity(0.62))
    }

    private func connect() {
        validationMessage = ""
        let configuration: LingShuBrainSetupConfiguration
        do {
            configuration = try .make(
                route: route,
                token: token,
                selectedModel: selectedModel,
                customEndpoint: customEndpoint,
                customModel: customModel
            )
        } catch {
            if let inputError = error as? LingShuBrainSetupInputError {
                validationMessage = state.loc(inputError.localizedDescription, inputError.englishDescription)
            } else {
                validationMessage = error.localizedDescription
            }
            return
        }

        isConnecting = true
        Task { @MainActor in
            let result = await state.installBrainFromSetup(configuration)
            isConnecting = false
            if !result.ok { validationMessage = result.detail }
        }
    }
}
