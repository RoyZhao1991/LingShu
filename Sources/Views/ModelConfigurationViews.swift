import SwiftUI

struct ModelConfigurationView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(icon: "slider.horizontal.3", title: "模型网关配置", subtitle: "Codex Auth 登录授权 + 国内外热门大模型 API + 本地模型 + 自定义兼容接口")

                PermissionBoundaryCard(state: state)

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(icon: "person.badge.key", title: "Codex Auth", subtitle: "复用本机 Codex / ChatGPT 登录授权")

                        ConfigRow(title: "Codex CLI", icon: "terminal") {
                            TextField(state.defaultCodexCLIPath, text: $state.codexCLIPath)
                                .textFieldStyle(.roundedBorder)
                        }

                        ConfigRow(title: "登录状态", icon: "link") {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(state.codexAuthStatus == "已登录" ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.codexAuthStatus == "已登录" ? "已登录：\(state.codexAuthDetail)" : state.codexAuthStatus)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Color.lingInk)
                                    Text("不会读取或展示 token，只调用 codex login status / codex exec。")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.lingMuted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 52)
                            .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        ConfigRow(title: "远端主线", icon: "network") {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(state.mainRemoteConnectionIndicatorColor)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.mainRemoteConnectionStatus)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Color.lingInk)
                                    Text(state.mainRemoteConnectionDetail)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.lingMuted)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 52)
                            .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        ConfigRow(title: "目标项目", icon: "folder") {
                            TextField("/Users/example/app", text: $state.codexWorkingDirectory)
                                .textFieldStyle(.roundedBorder)
                        }

                        ConfigRow(title: "心跳失联", icon: "waveform.path.ecg") {
                            Stepper("\(Int(state.codexTimeoutSeconds)) 秒", value: $state.codexTimeoutSeconds, in: 60...900, step: 30)
                        }

                        ConfigRow(title: "Codex Fast", icon: "bolt") {
                            Toggle("使用 Codex fast 档", isOn: $state.codexFastMode)
                                .toggleStyle(.switch)
                        }

                        HStack(spacing: 8) {
                            Button {
                                state.applyModelProvider("Codex Auth")
                            } label: {
                                Label("使用 Codex Auth", systemImage: state.usesCodexAuth ? "checkmark.circle.fill" : "circle")
                            }

                            Button {
                                state.refreshCodexAuthStatus()
                            } label: {
                                Label(state.isCheckingCodexAuth ? "检查中" : "检查", systemImage: "arrow.clockwise")
                            }
                            .disabled(state.isCheckingCodexAuth)

                            Button {
                                state.forceMainRemoteHealthProbe()
                            } label: {
                                Label("探活", systemImage: "waveform.path.ecg")
                            }

                            Button {
                                state.openCodexLogin()
                            } label: {
                                Label("登录", systemImage: "person.crop.circle.badge.checkmark")
                            }

                            Spacer()
                        }
                    }
                    .panelStyle()

                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(icon: "server.rack", title: "大模型网关", subtitle: "选择供应商预设，也可以手动改 endpoint 和模型名")

                        ConfigRow(title: "API 供应商", icon: "server.rack") {
                            Picker("", selection: Binding<String>(
                                get: { state.usesCodexAuth ? "__choose_api_provider__" : state.modelProvider },
                                set: { state.applyModelProvider($0) }
                            )) {
                                Text("选择 API 供应商").tag("__choose_api_provider__")
                                    .disabled(true)
                                ForEach(ModelProviderPreset.apiCatalog) { preset in
                                    Text(preset.displayName).tag(preset.name)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        if state.usesCodexAuth {
                            Text("当前主通道是 Codex Auth。选择上方任一 API 供应商后，灵枢会切换到大模型网关配置。")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.lingMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let preset = state.selectedModelPreset {
                            HStack(spacing: 6) {
                                ProviderMetadataPill(text: preset.region, icon: "globe.asia.australia")
                                ProviderMetadataPill(text: preset.category, icon: "square.stack.3d.up")
                                ProviderMetadataPill(text: preset.protocolName, icon: "point.3.connected.trianglepath.dotted")
                                Spacer()
                            }
                        }

                        if !state.usesCodexAuth {
                            ConfigRow(title: "接口地址", icon: "link") {
                                TextField("https://api.openai.com/v1", text: $state.endpoint)
                                    .textFieldStyle(.roundedBorder)
                            }

                            ConfigRow(title: "模型名称", icon: "brain") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if !state.availableModelNames.isEmpty {
                                        Picker("", selection: $state.modelName) {
                                            ForEach(state.availableModelNames, id: \.self) { model in
                                                Text(model).tag(model)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                    }

                                    TextField("gpt-5.5 / qwen-plus / deepseek-chat / custom-model", text: $state.modelName)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            ConfigRow(title: "访问密钥", icon: "key") {
                                SecureField(state.selectedModelPreset?.authMode ?? "API Key", text: $state.apiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        ConfigRow(title: "连接状态", icon: "link") {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(state.isModelConnected ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.modelConnectionState)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Color.lingInk)
                                    Text(state.selectedModelPreset?.note ?? "自定义模型网关。")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.lingMuted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 52)
                            .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .panelStyle()
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(icon: "checkmark.shield", title: "执行策略", subtitle: "先让灵枢可控，再让灵枢强大")

                        HStack(spacing: 16) {
                            Toggle("本地审计日志", isOn: $state.enableLocalAudit)
                                .toggleStyle(.switch)
                            Toggle("高风险操作需要人工确认", isOn: $state.requireHumanApproval)
                                .toggleStyle(.switch)
                            Toggle("灵枢回复语音朗读", isOn: $state.voiceOutputEnabled)
                                .toggleStyle(.switch)
                            Toggle("本地模型流式多轮", isOn: $state.localStreamingDialogueEnabled)
                                .toggleStyle(.switch)
                        }

                        Text("本地模型流式多轮仅在 Ollama、LM Studio、vLLM、localhost 等本地/自托管网关下生效；语音转写后仍统一进入主文本对话流程。")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.lingMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("随机性：\(String(format: "%.1f", state.temperature))")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.lingInk)
                            Slider(value: $state.temperature, in: 0...1, step: 0.1)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("上下文预算：\(Int(state.contextBudget)) tokens")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.lingInk)
                            Slider(value: $state.contextBudget, in: 8000...256000, step: 8000)
                        }
                    }
                    .panelStyle()
                }

                ModelCatalogView(
                    selectedProvider: state.modelProvider,
                    presets: ModelProviderPreset.apiCatalog,
                    onSelect: { preset in
                        state.applyModelProvider(preset.name)
                    }
                )
                .panelStyle()

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(icon: "doc.text.magnifyingglass", title: "配置说明", subtitle: "Codex Auth 走本机 Codex 登录；API Key 通道后续可接 Keychain 和 Responses API")
                    CodeBlockView(text:
"""
模型访问流：
用户 -> 灵枢对话层 -> 模型网关 -> 治理链路 -> 能力节点 -> 工具执行

当前实现：
1. Codex Auth：调用本机 codex login status 检查 ChatGPT 授权。
2. Codex Bridge：调用 codex exec，可在沙箱权限或完整权限下处理目标项目。
3. 大模型网关：内置国内外热门供应商预设，支持 OpenAI 兼容接口、自托管、本地模型和自定义网关。
4. API Key：原型阶段只保存界面状态，下一步应写入 macOS Keychain。
5. 代码修改、邮件发送、删除文件等高风险操作必须经过灵枢确认。
"""
                    )
                }
                .panelStyle()
            }
            .padding(22)
        }
    }
}

struct PermissionBoundaryCard: View {
    @ObservedObject var state: LingShuState

    private var modeColor: Color {
        state.codexPermissionMode == .fullAccess ? .orange : .teal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(modeColor)
                    .frame(width: 42, height: 42)
                    .background(modeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("权限与执行边界")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.lingInk)
                    Text("决定灵枢调用 Codex/模型执行任务时能接触到哪些文件，以及高风险动作是否需要你确认。")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.lingMuted)
                }

                Spacer()

                Picker("", selection: $state.codexPermissionMode) {
                    ForEach(CodexPermissionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            HStack(alignment: .top, spacing: 12) {
                PermissionMetricCard(
                    title: "当前权限",
                    value: state.codexPermissionMode.rawValue,
                    detail: state.codexPermissionMode.detail,
                    tint: modeColor
                )
                PermissionMetricCard(
                    title: "Codex 参数",
                    value: "--sandbox \(state.codexPermissionMode.sandboxArgument)",
                    detail: state.codexPermissionMode == .sandbox ? "日常工程迭代建议保持此模式。" : "仅在你明确授权系统级操作时启用。",
                    tint: modeColor
                )
                PermissionMetricCard(
                    title: "人工确认",
                    value: state.requireHumanApproval ? "已开启" : "未开启",
                    detail: state.requireHumanApproval ? "代码修改、删除、外部发送等高风险动作会先停在确认口。" : "灵枢会按当前权限边界自动推进。",
                    tint: state.requireHumanApproval ? .teal : .orange
                )
            }

            HStack(spacing: 16) {
                Toggle("高风险操作需要人工确认", isOn: $state.requireHumanApproval)
                    .toggleStyle(.switch)
                Toggle("本地审计日志", isOn: $state.enableLocalAudit)
                    .toggleStyle(.switch)
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .panelStyle()
    }
}

struct PermissionMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.lingMuted)
            Text(value)
                .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.lingInk.opacity(0.72))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.22))
        }
    }
}

struct ProviderMetadataPill: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(Color.lingInk.opacity(0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.07))
            }
    }
}

struct ModelCatalogView: View {
    let selectedProvider: String
    let presets: [ModelProviderPreset]
    let onSelect: (ModelProviderPreset) -> Void

    private var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 10, alignment: .top)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "square.grid.3x3", title: "热门模型目录", subtitle: "国内、海外、聚合平台、本地模型和自托管网关预设")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        onSelect(preset)
                    } label: {
                        ModelProviderPresetCell(preset: preset, selected: selectedProvider == preset.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ModelProviderPresetCell: View {
    let preset: ModelProviderPreset
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.hexagon.fill" : "hexagon")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(selected ? Color.teal : Color.lingMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.lingInk)
                        .lineLimit(1)
                    Text("\(preset.region) / \(preset.category)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.lingMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }

            Text(preset.defaultModels.prefix(3).joined(separator: " · "))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.lingInk.opacity(0.72))
                .lineLimit(2)

            Text(preset.protocolName)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.teal)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(selected ? Color.teal.opacity(0.12) : Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.teal.opacity(0.42) : Color.black.opacity(0.07))
        }
    }
}

struct ConfigRow<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.lingInk)
            content
        }
    }
}
