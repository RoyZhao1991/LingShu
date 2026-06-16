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
    @State private var channelTab: ChannelTab = .brain
    @State private var sheet: SheetRoute?

    enum ChannelTab: String, CaseIterable, Identifiable {
        case brain = "中枢 · 脑"
        case voice = "语音 · 口"
        case perception = "感知 · 眼/耳"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .brain: "brain.head.profile"
            case .voice: "waveform"
            case .perception: "eye"
            }
        }
    }
    enum SheetRoute: Identifiable {
        case add
        case edit(String)
        var id: String { if case .edit(let p) = self { return "edit-\(p)" }; return "add" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "antenna.radiowaves.left.and.right", title: "模型通道", subtitle: "中枢/眼/耳/口各能力通道在此配置 + 校验;只有校验通过的才会被各模态和子线程切换用")

                // 子 tab:不同通道类型分页(中枢/语音/感知)
                HStack(spacing: 6) {
                    ForEach(ChannelTab.allCases) { item in
                        Button { channelTab = item } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon).font(.system(size: 11, weight: .semibold))
                                Text(item.rawValue).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(channelTab == item ? Color.lingVoid : .white.opacity(0.7))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(channelTab == item ? Color.lingHolo : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if channelTab == .brain {
                        Button { sheet = .add } label: {
                            Label("新增模型", systemImage: "plus.circle.fill").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.lingVoid)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    switch channelTab {
                    case .brain: brainRows
                    case .voice: voiceRows
                    case .perception: perceptionRows
                    }
                }

                executionPanel
            }
            .padding(22)
        }
        .sheet(item: $sheet) { route in
            LingShuModelChannelSheet(state: state, route: route) { sheet = nil }
                .frame(minWidth: 560, minHeight: 470)
        }
    }

    @ViewBuilder private var brainRows: some View {
        let providers = state.configuredTextProviders()
        if providers.isEmpty {
            Text("还没有接入任何文本模型。点「新增模型」选一个供应商,配置 endpoint / 模型 / 密钥。")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        } else {
            ForEach(providers) { preset in
                LingShuChannelRow(
                    state: state,
                    title: preset.name,
                    subtitle: "\(preset.region) · \(preset.name == state.modelProvider ? state.modelName : (preset.defaultModels.first ?? ""))",
                    channelKey: LingShuState.brainChannelKey(preset.name),
                    isActive: preset.name == state.modelProvider,
                    onValidate: { await state.validateBrainChannel(preset.name) },
                    onUse: preset.name == state.modelProvider ? nil : { state.applyModelProvider(preset.name) },
                    onEdit: { sheet = .edit(preset.name) }
                )
            }
        }
    }

    @ViewBuilder private var voiceRows: some View {
        ForEach(state.ttsChannelDescriptors) { d in
            LingShuChannelRow(
                state: state, title: d.displayName, subtitle: d.deployment,
                channelKey: LingShuState.ttsChannelKey(d.id),
                isActive: state.voiceManager?.speechOutputProvider.id == d.id,
                onValidate: { await state.validateTTSChannel(d) },
                onUse: {
                    state.voiceManager?.speechOutputProvider = d
                    if !d.defaultEndpoint.isEmpty { state.voiceManager?.speechOutputEndpoint = d.defaultEndpoint }
                },
                onEdit: nil
            )
        }
    }

    @ViewBuilder private var perceptionRows: some View {
        LingShuChannelRow(
            state: state, title: "视觉 / 视频 · 数据网关 VL", subtitle: "swds-vision-fast · Qwen2.5-VL",
            channelKey: LingShuState.visionChannelKey, isActive: false,
            onValidate: { await state.validateVisionChannel() }, onUse: nil, onEdit: nil
        )
        LingShuChannelRow(
            state: state, title: "语音识别 · 本机", subtitle: "macOS SFSpeech 本机能力,始终可用",
            channelKey: LingShuState.asrLocalChannelKey, isActive: false,
            onValidate: { state.validateASRLocalChannel() }, onUse: nil, onEdit: nil
        )
    }

    private var executionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "checkmark.shield", title: "执行策略", subtitle: "工作目录 · 权限边界 · 语音/计算机操作")

            LingShuConfigLine(title: "目标", value: state.codexWorkingDirectory)
            TextField("目标项目目录", text: $state.codexWorkingDirectory).textFieldStyle(.roundedBorder)

            Picker("权限模式", selection: $state.codexPermissionMode) {
                ForEach(CodexPermissionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 18) {
                Toggle("高风险需人工确认", isOn: $state.requireHumanApproval).toggleStyle(.switch)
                Toggle("语音朗读", isOn: $state.voiceOutputEnabled).toggleStyle(.switch)
                Toggle("本地流式多轮", isOn: $state.localStreamingDialogueEnabled).toggleStyle(.switch)
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.76))

            Toggle("计算机直接操作(截屏/点击/键入)", isOn: $state.computerControlEnabled)
                .toggleStyle(.switch).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.76))

            VStack(alignment: .leading, spacing: 6) {
                Text("随机性 \(String(format: "%.1f", state.temperature))").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Slider(value: $state.temperature, in: 0...1, step: 0.1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 暗色科技感的能力通道一行:名称 + 当前·在线 + 校验状态徽标;校验/使用/修改。中枢/语音/感知共用。
struct LingShuChannelRow: View {
    @ObservedObject var state: LingShuState
    let title: String
    let subtitle: String
    let channelKey: String
    let isActive: Bool
    let onValidate: () async -> Void
    let onUse: (() -> Void)?
    let onEdit: (() -> Void)?

    private var validation: LingShuChannelValidation? { state.channelValidation(channelKey) }
    private var validating: Bool { state.isChannelValidating(channelKey) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isActive ? Color.lingHolo : .white.opacity(0.32))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(.white)
                    if isActive { pill("当前 · 在线", Color.lingHolo) }
                    statusBadge
                }
                Text(subtitle).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }

            Spacer()

            chip(validating ? "校验中…" : "校验", disabled: validating) { Task { await onValidate() } }
            if let onUse { chip("使用") { onUse() } }
            if let onEdit { chip("修改") { onEdit() } }
        }
        .padding(12)
        .background(isActive ? Color.lingHolo.opacity(0.10) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isActive ? Color.lingHolo.opacity(0.34) : Color.white.opacity(0.08))
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let (text, color): (String, Color) = {
            if validating { return ("校验中…", .orange) }
            guard let v = validation else { return ("未校验", .white.opacity(0.4)) }
            return v.ok ? ("✅ 校验通过", .green) : ("❌ " + String(v.detail.prefix(12)), .red)
        }()
        pill(text, color)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func chip(_ label: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(disabled ? 0.4 : 0.82))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 新增/修改 中枢模型 弹窗(暗色):新增先选供应商,再配 endpoint/模型/密钥;密钥不返显(留空=不变)。
struct LingShuModelChannelSheet: View {
    @ObservedObject var state: LingShuState
    let route: LingShuModelGatewaySurface.SheetRoute
    let dismiss: () -> Void

    @State private var provider: String
    @State private var endpoint: String
    @State private var model: String
    @State private var key: String

    init(state: LingShuState, route: LingShuModelGatewaySurface.SheetRoute, dismiss: @escaping () -> Void) {
        self.state = state; self.route = route; self.dismiss = dismiss
        switch route {
        case .add:
            _provider = State(initialValue: ""); _endpoint = State(initialValue: ""); _model = State(initialValue: ""); _key = State(initialValue: "")
        case .edit(let p):
            let preset = ModelProviderPreset.apiCatalog.first { $0.name == p }
            let active = (p == state.modelProvider)
            _provider = State(initialValue: p)
            _endpoint = State(initialValue: active ? state.endpoint : (preset?.endpoint ?? ""))
            _model = State(initialValue: active ? state.modelName : (preset?.defaultModels.first ?? ""))
            _key = State(initialValue: "")
        }
    }

    private var isAdd: Bool { if case .add = route { return true }; return false }
    private var preset: ModelProviderPreset? { ModelProviderPreset.apiCatalog.first { $0.name == provider } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isAdd ? "新增模型" : "修改 · \(provider)").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white.opacity(0.5)) }.buttonStyle(.plain)
            }

            if isAdd {
                Picker("供应商", selection: $provider) {
                    Text("选择供应商").tag("")
                    ForEach(ModelProviderPreset.apiCatalog) { Text($0.displayName).tag($0.name) }
                }
                .pickerStyle(.menu)
                .onChange(of: provider) { _ in
                    if let p = preset { endpoint = p.endpoint; model = p.defaultModels.first ?? ""; key = "" }
                }
            }

            if !provider.isEmpty {
                fieldLabel("接口地址")
                TextField("https://api.deepseek.com", text: $endpoint).textFieldStyle(.roundedBorder)
                fieldLabel("模型名称")
                if let p = preset, !p.defaultModels.isEmpty {
                    Picker("", selection: $model) { ForEach(p.defaultModels, id: \.self) { Text($0).tag($0) } }.labelsHidden().pickerStyle(.menu)
                }
                TextField("deepseek-chat / gpt-5.5 / ...", text: $model).textFieldStyle(.roundedBorder)
                fieldLabel("访问密钥")
                SecureField(isAdd ? (preset?.authMode ?? "API Key") : "已配置(留空保持不变)", text: $key).textFieldStyle(.roundedBorder)
                if let note = preset?.note {
                    Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.bordered)
                Button("保存并使用") { save() }.buttonStyle(.borderedProminent).disabled(provider.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.lingVoid)
        .preferredColorScheme(.dark)
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
    }

    private func save() {
        guard !provider.isEmpty else { return }
        state.applyModelProvider(provider)
        if !endpoint.isEmpty { state.endpoint = endpoint }
        if !model.isEmpty { state.modelName = model }
        if !key.isEmpty { state.apiKey = key }
        dismiss()
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
