import SwiftUI

struct LingShuOperationsSurface: View {
    @ObservedObject var state: LingShuState

    private let gridColumns = [GridItem(.adaptive(minimum: 156), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(icon: "building.columns", title: "能力运维", subtitle: "能力节点实时状态 · 运行策略 · 会话池 · 事件流")

                // 能力节点矩阵：每个节点 = 角色名（字面）+ 实时运行态（服务状态）+ 负载条。
                Text("能力节点 · \(state.activeWorkerCount) 执行 / \(state.activeSupervisorCount) 监控 / \(state.agents.count) 注册")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(state.agents) { agent in
                        LingShuDualLayerCell(
                            label: agent.shortName,
                            value: agent.domain,
                            stateText: agentStateText(agent.state),
                            stateColor: agentStateColor(agent.state),
                            load: agent.load
                        )
                    }
                }

                // 运行策略：每条策略的开关真实状态。
                Text("运行策略")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    policyCell("人工确认", on: state.requireHumanApproval, onText: "高风险拦截", offText: "已放行")
                    policyCell("本地审计", on: state.enableLocalAudit, onText: "记录在册", offText: "未记录")
                    policyCell("语音播报", on: state.voiceOutputEnabled, onText: "已开启", offText: "静默")
                    policyCell("流式多轮", on: state.localStreamingDialogueEnabled, onText: "流式", offText: "整段")
                    LingShuDualLayerCell(
                        label: "会话池",
                        value: state.remoteSessionStatus,
                        stateText: state.remoteSessionPool.stats().running > 0 ? "运行中" : "空闲",
                        stateColor: state.remoteSessionPool.stats().running > 0 ? .lingHolo : .white.opacity(0.45)
                    )
                    LingShuDualLayerCell(
                        label: "主通道",
                        value: state.modelProvider,
                        stateText: state.isModelConnected ? "已接入" : "未接入",
                        stateColor: state.isModelConnected ? .lingHolo : .orange
                    )
                }

                // 事件流：底层服务事件，本身即第二层状态信息。
                Text("事件流 · \(state.eventLog.count) 条")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.eventLog.prefix(12).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Circle().fill(Color.lingHolo.opacity(0.7)).frame(width: 4, height: 4)
                            Text(item)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.66))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .lingShuHUDPanel(cornerLength: 6, fillOpacity: 0.03)
                    }
                }
            }
            .padding(22)
        }
    }

    private func policyCell(_ label: String, on: Bool, onText: String, offText: String) -> some View {
        LingShuDualLayerCell(
            label: label,
            value: on ? onText : offText,
            stateText: on ? "启用" : "关闭",
            stateColor: on ? .lingHolo : .white.opacity(0.45)
        )
    }

    private func agentStateText(_ s: StepState) -> String {
        switch s {
        case .waiting: "待命"
        case .running: "执行中"
        case .done: "完成"
        }
    }

    private func agentStateColor(_ s: StepState) -> Color {
        switch s {
        case .waiting: .white.opacity(0.45)
        case .running: .lingHolo
        case .done: .green
        }
    }
}

struct LingShuModelGatewaySurface: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(icon: "slider.horizontal.3", title: "模型访问配置", subtitle: "默认数据网络网关 · Codex Auth · 主流大模型 API · 本地模型")

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(icon: "person.badge.key", title: "Codex Auth", subtitle: "复用本机 Codex / ChatGPT 登录")

                        LingShuConfigLine(title: "CLI", value: state.codexCLIPath)
                        LingShuConfigLine(title: "状态", value: state.modelConnectionState)
                        LingShuConfigLine(title: "远端主线", value: state.mainRemoteConnectionStatus)
                        LingShuConfigLine(title: "探活详情", value: state.mainRemoteConnectionDetail)
                        LingShuConfigLine(title: "目标", value: state.codexWorkingDirectory)
                        LingShuConfigLine(title: "权限", value: "\(state.codexPermissionMode.rawValue) / \(state.codexPermissionMode.sandboxArgument)")

                        TextField("目标项目目录", text: $state.codexWorkingDirectory)
                            .textFieldStyle(.roundedBorder)

                        Picker("权限模式", selection: $state.codexPermissionMode) {
                            ForEach(CodexPermissionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Stepper("心跳失联阈值 \(Int(state.codexTimeoutSeconds)) 秒", value: $state.codexTimeoutSeconds, in: 60...900, step: 30)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.76))

                        Toggle("Codex Fast 模式", isOn: $state.codexFastMode)
                            .toggleStyle(.switch)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.76))

                        LingShuConfigLine(title: "档位", value: state.codexFastMode ? "Fast · 高推理档" : "标准 · 默认档")

                        HStack(spacing: 10) {
                            Button("使用 Codex Auth") {
                                state.applyModelProvider("Codex Auth")
                            }
                            Button(state.isCheckingCodexAuth ? "检查中" : "检查登录") {
                                state.refreshCodexAuthStatus()
                            }
                            .disabled(state.isCheckingCodexAuth)
                            Button("探活") {
                                state.forceMainRemoteHealthProbe()
                            }
                            Button("打开登录") {
                                state.openCodexLogin()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(icon: "server.rack", title: "大模型网关", subtitle: "支持 OpenAI 兼容接口、云厂商与本地模型")

                        Picker("供应商", selection: Binding<String>(
                            get: { state.modelProvider },
                            set: { state.applyModelProvider($0) }
                        )) {
                            ForEach(ModelProviderPreset.catalog) { preset in
                                Text(preset.displayName).tag(preset.name)
                            }
                        }
                        .pickerStyle(.menu)

                        TextField("Endpoint", text: $state.endpoint)
                            .textFieldStyle(.roundedBorder)
                        TextField("模型名称", text: $state.modelName)
                            .textFieldStyle(.roundedBorder)
                        SecureField(state.selectedModelPreset?.authMode ?? "API Key", text: $state.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Toggle("本地模型流式多轮对话", isOn: $state.localStreamingDialogueEnabled)
                            .toggleStyle(.switch)

                        LingShuConfigLine(title: "鉴权", value: state.apiKey.isEmpty ? "未配置 \(state.selectedModelPreset?.authMode ?? "凭据")" : "已配置 · 钥匙串")
                        LingShuConfigLine(title: "通道", value: state.isModelConnected ? "已接入 · \(state.modelName)" : "未接入")
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    ForEach(ModelProviderPreset.catalog) { preset in
                        Button {
                            state.applyModelProvider(preset.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(presetStateColor(preset))
                                        .frame(width: 6, height: 6)
                                        .shadow(color: presetStateColor(preset).opacity(0.8), radius: 3)
                                    Text(preset.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Spacer(minLength: 2)
                                    Text(presetStateText(preset))
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(presetStateColor(preset))
                                }
                                Text("\(preset.region) · \(preset.category)")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.54))
                                    .lineLimit(1)
                                Text(preset.defaultModels.prefix(2).joined(separator: " / "))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.lingHolo.opacity(0.78))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(state.modelProvider == preset.name ? Color.lingHolo.opacity(0.16) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(state.modelProvider == preset.name ? Color.lingHolo.opacity(0.42) : Color.white.opacity(0.08))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(22)
        }
    }
}

private extension LingShuModelGatewaySurface {
    func presetStateColor(_ preset: ModelProviderPreset) -> Color {
        if state.modelProvider == preset.name {
            return state.isModelConnected ? .lingHolo : .orange
        }
        return .white.opacity(0.32)
    }

    func presetStateText(_ preset: ModelProviderPreset) -> String {
        if state.modelProvider == preset.name {
            return state.isModelConnected ? "当前·在线" : "当前·未接入"
        }
        return "待启用"
    }
}

struct LingShuConfigLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.48))
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
            Spacer()
        }
        .padding(10)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
