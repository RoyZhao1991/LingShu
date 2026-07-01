import SwiftUI
import AppKit

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
                    .foregroundStyle(Color.lingFg.opacity(0.5))
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
                    .foregroundStyle(Color.lingFg.opacity(0.5))
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    policyCell("人工确认", on: state.requireHumanApproval, onText: "高风险拦截", offText: "已放行")
                    policyCell("本地审计", on: state.enableLocalAudit, onText: "记录在册", offText: "未记录")
                    policyCell("语音播报", on: state.voiceOutputEnabled, onText: "已开启", offText: "静默")
                    policyCell("流式多轮", on: state.localStreamingDialogueEnabled, onText: "流式", offText: "整段")
                    LingShuDualLayerCell(
                        label: "会话池",
                        value: state.remoteSessionStatus,
                        stateText: state.remoteSessionPool.stats().running > 0 ? "运行中" : "空闲",
                        stateColor: state.remoteSessionPool.stats().running > 0 ? .lingHolo : Color.lingFg.opacity(0.45)
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
                    .foregroundStyle(Color.lingFg.opacity(0.5))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.eventLog.prefix(12).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Circle().fill(Color.lingHolo.opacity(0.7)).frame(width: 4, height: 4)
                            Text(item)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.lingFg.opacity(0.66))
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
            stateColor: on ? .lingHolo : Color.lingFg.opacity(0.45)
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
        case .waiting: Color.lingFg.opacity(0.45)
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
        case vision = "视觉 · 眼"
        case hearing = "听觉 · 耳"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .brain: "brain.head.profile"
            case .voice: "waveform"
            case .vision: "eye"
            case .hearing: "ear"
            }
        }
    }
    enum SheetRoute: Identifiable {
        case add                                                                  // 中枢新增(选供应商)
        case edit(String)                                                         // 中枢修改
        case channel(key: String, title: String, endpoint: String, model: String) // 口/眼/耳 配置(名/端点/模型/密钥)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let p): "edit-\(p)"
            case .channel(let key, _, _, _): "ch-\(key)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "antenna.radiowaves.left.and.right", title: "模型通道", subtitle: "中枢/眼/耳/口各能力通道在此配置 + 校验;只有校验通过的才会被各模态和子线程切换用")

                // 配置加密导入/导出(换机/分享试用/开源安全):口令加密整包导出,一键导入即用。
                LingShuModelConfigPortabilityBar(state: state)

                // 脑力测试:跑一套难度不等的硬编码题测当前脑,出综合分(弹窗)。
                LingShuBrainBenchmarkBar(state: state)

                // 子 tab:不同通道类型分页(中枢/语音/感知)
                HStack(spacing: 6) {
                    ForEach(ChannelTab.allCases) { item in
                        Button { channelTab = item } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon).font(.system(size: 11, weight: .semibold))
                                Text(item.rawValue).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(channelTab == item ? Color.lingVoid : Color.lingFg.opacity(0.7))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(channelTab == item ? Color.lingHolo : Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    localModeChip
                    addControl
                }

                VStack(alignment: .leading, spacing: 10) {
                    switch channelTab {
                    case .brain: brainRows
                    case .voice: voiceRows
                    case .vision: visionRows
                    case .hearing: hearingRows
                    }
                }
            }
            .padding(22)
        }
        .sheet(item: $sheet) { route in
            if case let .channel(key, title, endpoint, model) = route {
                LingShuChannelConfigSheet(state: state, channelKey: key, title: title, defaultEndpoint: endpoint, defaultModel: model) { sheet = nil }
                    .frame(minWidth: 540, minHeight: 420)
            } else {
                LingShuModelChannelSheet(state: state, route: route) { sheet = nil }
                    .frame(minWidth: 560, minHeight: 470)
            }
        }
    }

    /// 每个模态各自的「新增」入口(像脑一样能加模型)。
    @ViewBuilder private var addControl: some View {
        switch channelTab {
        case .brain:
            accentButton("新增模型") { sheet = .add }
        case .voice:
            let pending = state.unconfiguredTTSDescriptors()
            if pending.isEmpty {
                EmptyView()
            } else {
                Menu {
                    ForEach(pending) { d in
                        Button(d.displayName) { sheet = .channel(key: LingShuState.ttsChannelKey(d.id), title: d.displayName, endpoint: d.defaultEndpoint, model: "") }
                    }
                } label: {
                    Label("新增声音", systemImage: "plus.circle.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.lingVoid).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        case .vision:
            accentButton("新增视觉") { sheet = .channel(key: LingShuState.visionCustomKey, title: "自定义视觉网关", endpoint: "", model: "") }
        case .hearing:
            accentButton("新增识别") { sheet = .channel(key: LingShuState.asrCustomKey, title: "自定义语音识别", endpoint: "", model: "") }
        }
    }

    private func accentButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: "plus.circle.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.lingVoid).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 本机有兜底方案的能力(耳/口)用的「本地模式」轻量开关:只在语音/听觉 tab 的头部一行显示,说明走 tooltip。
    @ViewBuilder private var localModeChip: some View {
        switch channelTab {
        case .voice:
            compactLocalToggle(isOn: $state.ttsLocalModeEnabled,
                               help: "本地模式 — 开:强制本机系统语音。关:优先数据网关情绪语音,不可用时仍兜底本机。")
        case .hearing:
            compactLocalToggle(isOn: $state.asrLocalModeEnabled,
                               help: "本地模式 — 开:强制本机识别(实时麦克风兜底永远可用)。关:偏好数据网关云端 ASR。当前实时麦克风以本机识别为主。")
        case .brain, .vision:
            EmptyView()
        }
    }

    private func compactLocalToggle(isOn: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: isOn) {
            Text("本地模式").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.7))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
        .help(help)
    }

    @ViewBuilder private var brainRows: some View {
        directToBrainStatus
        actualBrainStatus
        let providers = state.configuredTextProviders()
        if providers.isEmpty {
            Text("还没有接入任何文本模型。点「新增模型」选一个供应商,配置 endpoint / 模型 / 密钥。")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        } else {
            ForEach(providers) { preset in
                VStack(spacing: 6) {
                    LingShuChannelRow(
                        state: state,
                        title: preset.name,
                        subtitle: "\(preset.region) · \(preset.name == state.modelProvider ? state.modelName : (preset.defaultModels.first ?? "")) · \(state.prefixCacheStrategy(for: preset).shortLabel)",
                        channelKey: LingShuState.brainChannelKey(preset.name),
                        isActive: preset.name == state.modelProvider,
                        onValidate: { await state.validateBrainChannel(preset.name) },
                        onUse: preset.name == state.modelProvider ? nil : { state.applyModelProvider(preset.name) },
                        onEdit: { sheet = .edit(preset.name) },
                        balance: state.channelBalance(LingShuState.brainChannelKey(preset.name)),
                        balanceSupported: LingShuChannelBalance.isSupported(provider: preset.name),
                        balanceFetching: state.isChannelBalanceFetching(LingShuState.brainChannelKey(preset.name)),
                        onBalance: { await state.fetchBrainChannelBalance(preset.name) }
                    )
                    // **当前激活的供应商有 ≥2 个可选模型 → 内联下拉框**:免开「修改」弹窗即可一键换模型(用过的自定义模型也记着、不消失)。
                    if preset.name == state.modelProvider {
                        let options = state.brainModelOptions(for: preset)
                        if options.count >= 2 { brainModelPicker(options) }
                    }
                }
            }
        }
    }

    /// 当前脑的内联「模型」下拉框:在已激活供应商内一键换模型(端点/密钥不动,会话即时重建)。仅当该供应商有多个可选模型时显示。
    private func brainModelPicker(_ options: [String]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.lingHolo.opacity(0.85))
            Text("模型").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.6))
            Picker("", selection: Binding(
                get: { state.modelName },
                set: { state.selectActiveBrainModel($0) }
            )) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: 300)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.lingFg.opacity(0.04)))
        .padding(.leading, 18)
    }

    /// 附件入脑策略(**自动按脑能力,无手动开关** 2026-06-28 用户定调):多模态脑→对话附件原图直发它;非多模态脑→VL 抽成文字(零留存)。
    /// 态势感知(环境感知)不在此列——一律强制 VL/零留存。这里只做**状态展示**(让用户知道附件会怎么处理),不再是可切换的控制。
    private var directToBrainStatus: some View {
        let vision = LingShuMultimodal.isVisionCapable(provider: state.modelProvider, model: state.modelName)
        return HStack(spacing: 12) {
            Image(systemName: vision ? "photo.on.rectangle.angled" : "doc.text.magnifyingglass")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(vision ? Color.lingHolo : Color.lingFg.opacity(0.55))
            VStack(alignment: .leading, spacing: 3) {
                Text("附件入脑(自动按脑能力)").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg)
                Text(vision
                     ? "当前脑「\(state.modelName)」多模态 → 对话附件(图片/PDF)原图直发它,用原生视觉看。"
                     : "当前脑「\(state.modelName)」非多模态 → 对话附件走 VL 抽成文字再喂(零留存)。换多模态脑(如 Claude)即原图直发。")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.lingFg.opacity(0.08)) }
    }

    /// **实际在用(地面真相,2026-06-29)**:最近一次真实请求实际用的脑——和"选中的通道"分开,治"显示的≠真用的"。
    /// 与选中一致=绿勾;不一致=橙色告警(选中后还没发请求/会话快照滞后)。还没发过请求则提示"发一条消息后显示"。
    @ViewBuilder private var actualBrainStatus: some View {
        let selected = "\(state.modelProvider) / \(state.modelName)"
        let actual = state.actualBrainModel.isEmpty ? "" : "\(state.actualBrainProvider) / \(state.actualBrainModel)"
        let matches = !actual.isEmpty && state.actualBrainProvider == state.modelProvider && state.actualBrainModel == state.modelName
        let fmt: (Date) -> String = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: $0) }
        HStack(spacing: 12) {
            Image(systemName: actual.isEmpty ? "clock.badge.questionmark" : (matches ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(actual.isEmpty ? Color.lingFg.opacity(0.45) : (matches ? Color.green.opacity(0.85) : Color.orange))
            VStack(alignment: .leading, spacing: 3) {
                Text("实际在用(最近一次真实请求)").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg)
                if actual.isEmpty {
                    Text("还没发过真实请求——发一条消息后,这里显示**此刻真在干活的脑**(地面真相,不是选中徽标)。")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                } else if matches {
                    Text("\(actual)" + (state.actualBrainAt.map { "(\(fmt($0)))" } ?? "") + " —— 与选中一致 ✓")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.5))
                } else {
                    Text("⚠️ 实际:\(actual)" + (state.actualBrainAt.map { "(\(fmt($0)))" } ?? "") + " —— 与选中「\(selected)」**不一致**!可能选中后还没发请求,或会话未重建。再发一条消息以对齐。")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.orange.opacity(0.95)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke((actual.isEmpty || matches ? Color.lingFg.opacity(0.08) : Color.orange.opacity(0.4))) }
    }

    @ViewBuilder private var voiceRows: some View {
        ForEach(state.configuredTTSDescriptors()) { d in
            let key = LingShuState.ttsChannelKey(d.id)
            LingShuChannelRow(
                state: state, title: state.ttsDisplayName(d),
                subtitle: state.channelConfig(key).model.isEmpty ? d.deployment : state.channelConfig(key).model,
                channelKey: key,
                isActive: state.voiceManager?.speechOutputProvider.id == d.id,
                onValidate: { await state.validateTTSChannel(d) },
                onUse: {
                    state.voiceManager?.speechOutputProvider = d
                    let ep = state.channelConfig(key).endpoint
                    state.voiceManager?.speechOutputEndpoint = ep.isEmpty ? d.defaultEndpoint : ep
                },
                onEdit: { sheet = .channel(key: key, title: state.ttsDisplayName(d), endpoint: state.channelConfig(key).endpoint.isEmpty ? d.defaultEndpoint : state.channelConfig(key).endpoint, model: state.channelConfig(key).model) }
            )
        }
    }

    @ViewBuilder private var visionRows: some View {
        LingShuChannelRow(
            state: state, title: state.channelDisplayName(LingShuState.visionChannelKey, default: "视觉 / 视频 · 数据网关 VL"),
            subtitle: state.channelConfig(LingShuState.visionChannelKey).model.isEmpty ? "swds-vision-fast · Qwen2.5-VL" : state.channelConfig(LingShuState.visionChannelKey).model,
            channelKey: LingShuState.visionChannelKey,
            isActive: state.isChannelValidated(LingShuState.visionChannelKey),
            onValidate: { await state.validateVisionChannel() }, onUse: nil,
            onEdit: { sheet = .channel(key: LingShuState.visionChannelKey, title: "视觉 · 数据网关 VL", endpoint: LingShuState.perceptionGatewayEndpoint, model: LingShuState.visionDefaultModel) }
        )
        if state.hasChannelConfig(LingShuState.visionCustomKey) {
            LingShuChannelRow(
                state: state, title: state.channelDisplayName(LingShuState.visionCustomKey, default: "自定义视觉网关"),
                subtitle: state.channelConfig(LingShuState.visionCustomKey).endpoint,
                channelKey: LingShuState.visionCustomKey, isActive: false,
                onValidate: { await state.validateVisionChannel() }, onUse: nil,
                onEdit: { sheet = .channel(key: LingShuState.visionCustomKey, title: "自定义视觉网关", endpoint: state.channelConfig(LingShuState.visionCustomKey).endpoint, model: state.channelConfig(LingShuState.visionCustomKey).model) }
            )
        }
    }

    @ViewBuilder private var hearingRows: some View {
        LingShuChannelRow(
            state: state, title: state.channelDisplayName(LingShuState.asrChannelKey, default: "语音识别 · 数据网关"),
            subtitle: state.channelConfig(LingShuState.asrChannelKey).model.isEmpty ? "数据网络模型网关 · swds-realtime-hearing" : state.channelConfig(LingShuState.asrChannelKey).model,
            channelKey: LingShuState.asrChannelKey,
            isActive: state.isChannelValidated(LingShuState.asrChannelKey) && !state.asrLocalModeEnabled,
            onValidate: { state.validateASRChannel(LingShuState.asrChannelKey) }, onUse: nil,
            onEdit: { sheet = .channel(key: LingShuState.asrChannelKey, title: "语音识别 · 数据网关", endpoint: LingShuState.perceptionGatewayEndpoint, model: LingShuState.asrDefaultModel) }
        )
        if state.hasChannelConfig(LingShuState.asrCustomKey) {
            LingShuChannelRow(
                state: state, title: state.channelDisplayName(LingShuState.asrCustomKey, default: "自定义语音识别"),
                subtitle: state.channelConfig(LingShuState.asrCustomKey).endpoint,
                channelKey: LingShuState.asrCustomKey, isActive: false,
                onValidate: { state.validateASRChannel(LingShuState.asrCustomKey) }, onUse: nil,
                onEdit: { sheet = .channel(key: LingShuState.asrCustomKey, title: "自定义语音识别", endpoint: state.channelConfig(LingShuState.asrCustomKey).endpoint, model: state.channelConfig(LingShuState.asrCustomKey).model) }
            )
        }
    }

}

/// 执行策略=独立配置(不在模型通道里):工作目录 · 常规偏好(语音/随机性)· 高风险边界(权限模式/人工确认/计算机操作)。
struct LingShuExecutionPolicySurface: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "gearshape", title: state.loc("系统配置", "System"), subtitle: state.loc("界面 · 目录 · 偏好 · 安全", "UI · Directory · Preferences · Security"))

            // 统一「名称：控件」对齐列表:标签定宽右对齐(冒号对齐)→ 所有控件左缘对齐;每项单行不换行,无分组标题/配色。
            VStack(alignment: .leading, spacing: 14) {
                row(state.loc("界面语言", "Language")) {
                    Picker("Language", selection: $state.language) {
                        ForEach(LingShuVoiceLanguage.allCases) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                row(state.loc("工作目录", "Working dir")) {
                    TextField(state.loc("项目目录绝对路径", "Absolute project path"), text: $state.agentWorkingDirectory)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced)).frame(maxWidth: 460)
                }
                row(state.loc("语音朗读", "Speak aloud")) {
                    Toggle("", isOn: $state.voiceOutputEnabled).toggleStyle(.switch).labelsHidden()
                }
                row(state.loc("随机性", "Temperature")) {
                    Slider(value: $state.temperature, in: 0...1, step: 0.1).frame(width: 300)
                    Text(String(format: "%.1f", state.temperature)).font(.system(size: 12.5, weight: .bold, design: .monospaced)).foregroundStyle(Color.lingHolo)
                }

                Divider().overlay(Color.lingFg.opacity(0.08))

                row(state.loc("权限模式", "Permission mode")) {
                    Picker("", selection: $state.executionPermissionMode) {
                        ForEach(LingShuExecutionPermissionMode.allCases) { Text(state.loc($0.rawValue, $0.englishName)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                row(state.loc("高风险需人工确认", "Confirm high-risk")) {
                    Toggle("", isOn: $state.requireHumanApproval).toggleStyle(.switch).labelsHidden()
                }
                row(state.loc("计算机直接操作", "Computer control")) {
                    Toggle("", isOn: $state.computerControlEnabled).toggleStyle(.switch).labelsHidden()
                    Text(state.loc("开启后向系统申请辅助功能 + 屏幕录制授权", "requests Accessibility + Screen Recording"))
                        .font(.system(size: 10.5)).foregroundStyle(Color.lingFg.opacity(0.4)).lineLimit(1)
                }
            }
            .padding(16)
            .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            LingShuSystemPermissionsPanel(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
    }

    /// 统一一行:`名称：` 定宽右对齐(中文用全角冒号、英文半角)+ 控件左缘对齐;单行不换行。
    @ViewBuilder private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label + state.loc("：", ":"))
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.72))
                .frame(width: 152, alignment: .trailing).lineLimit(1)
            content()
            Spacer(minLength: 0)
        }
    }

    /// 带小标题的字段(标题在上、控件在下),用于同行并排多个字段。
    @ViewBuilder private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.6))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 系统权限面板:屏幕录制 + 系统通知,可在配置里**主动授予**(避免录制/推送时人不在却没授权而失败)。
struct LingShuSystemPermissionsPanel: View {
    @ObservedObject var state: LingShuState
    @ObservedObject private var notifications = LingShuNotificationCenter.shared
    @State private var screenRecordingTrusted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                icon: "lock.shield",
                title: state.loc("系统权限", "System Permissions"),
                subtitle: state.loc("提前授予,避免会议录制/主动推送时人不在却没权限而失败", "Grant ahead so recording / push won't fail while you're away")
            )

            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: state.loc("屏幕录制", "Screen Recording"),
                detail: state.loc("听系统声音 / 看屏幕(会议纪要必需)", "System audio / screen (required for meeting minutes)"),
                granted: screenRecordingTrusted,
                grantTitle: state.loc("授予", "Grant")
            ) {
                _ = LingShuComputerControl.requestScreenCaptureAccess()
                openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { screenRecordingTrusted = LingShuComputerControl.isScreenCaptureTrusted() }
            }

            permissionRow(
                icon: "bell.badge",
                title: state.loc("系统通知", "Notifications"),
                detail: state.loc("灵枢主动推送横幅(纪要完成 / 异常提醒)", "Lets 灵枢 push banners (minutes done / alerts)"),
                granted: notifications.authorized,
                grantTitle: state.loc("授予", "Grant")
            ) {
                notifications.requestAuthorization()
                openSettings("x-apple.systempreferences:com.apple.preference.notifications")
            }
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
        .onAppear {
            screenRecordingTrusted = LingShuComputerControl.isScreenCaptureTrusted()
            notifications.refreshStatus()
        }
    }

    @ViewBuilder
    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, grantTitle: String, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(granted ? .green : Color.lingHolo).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
                Text(detail).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.45)).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(granted ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(granted ? state.loc("已授权", "Granted") : state.loc("未授权", "Not granted"))
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.6))
            }
            if !granted {
                Button(action: grant) {
                    Text(grantTitle).font(.system(size: 11, weight: .bold))
                }.buttonStyle(.borderedProminent).controlSize(.small).tint(.lingHolo)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func openSettings(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
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
    var editLabel: String = "修改"
    // 账号余额口子(按需,默认关;只有支持余额查询的厂商才传)。
    var balance: LingShuChannelBalance.Result? = nil
    var balanceSupported: Bool = false
    var balanceFetching: Bool = false
    var onBalance: (() async -> Void)? = nil

    private var validation: LingShuChannelValidation? { state.channelValidation(channelKey) }
    private var validating: Bool { state.isChannelValidating(channelKey) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isActive ? Color.lingHolo : Color.lingFg.opacity(0.32))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(Color.lingFg)
                    if isActive { pill("当前 · 在线", Color.lingHolo) }
                    statusBadge
                    if let b = balance { pill("余额 " + b.display, b.available ? Color.lingHolo : .orange) }
                    else if balanceFetching { pill("查余额…", .orange) }
                }
                Text(subtitle).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.5)).lineLimit(1)
            }

            Spacer()

            if balanceSupported, let onBalance {
                chip(balanceFetching ? "查询中…" : "余额", disabled: balanceFetching) { Task { await onBalance() } }
            }
            chip(validating ? "校验中…" : "校验", disabled: validating) { Task { await onValidate() } }
            if let onUse { chip("使用") { onUse() } }
            if let onEdit { chip(editLabel) { onEdit() } }
        }
        .padding(12)
        .background(isActive ? Color.lingHolo.opacity(0.10) : Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isActive ? Color.lingHolo.opacity(0.34) : Color.lingFg.opacity(0.08))
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let (text, color): (String, Color) = {
            if validating { return ("校验中…", .orange) }
            guard let v = validation else { return ("未校验", Color.lingFg.opacity(0.4)) }
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
                .foregroundStyle(Color.lingFg.opacity(disabled ? 0.4 : 0.82))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.lingFg.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        if case let .edit(p) = route {
            let preset = ModelProviderPreset.apiCatalog.first { $0.name == p }
            let active = (p == state.modelProvider)
            _provider = State(initialValue: p)
            _endpoint = State(initialValue: active ? state.endpoint : (preset?.endpoint ?? ""))
            _model = State(initialValue: active ? state.modelName : (preset?.defaultModels.first ?? ""))
            _key = State(initialValue: "")
        } else {
            // .add(及永远走不到这里的 .renameTTS,它被路由去 LingShuTTSRenameSheet)
            _provider = State(initialValue: ""); _endpoint = State(initialValue: ""); _model = State(initialValue: ""); _key = State(initialValue: "")
        }
    }

    private var isAdd: Bool { if case .add = route { return true }; return false }
    private var preset: ModelProviderPreset? { ModelProviderPreset.apiCatalog.first { $0.name == provider } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isAdd ? "新增模型" : "修改 · \(provider)").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.lingFg)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color.lingFg.opacity(0.5)) }.buttonStyle(.plain)
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
                    Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
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
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.6))
    }

    private func save() {
        guard !provider.isEmpty else { return }
        state.applyModelProvider(provider)
        if !endpoint.isEmpty { state.endpoint = endpoint }
        if !model.isEmpty { state.modelName = model; state.rememberBrainModel(model, for: provider) }   // 记进下拉,手填的自定义模型切走也不丢
        if !key.isEmpty { state.apiKey = key }
        dismiss()
    }
}

/// 口/眼/耳 能力通道配置弹窗(暗色):自定义显示名 + 接口地址 + 模型 + 密钥(不返显,留空不变)。
/// 名字写死不准(如"男声"实为女声)、要改端点/模型/密钥都在这里。保存到 channelConfigs + credentialStore。
struct LingShuChannelConfigSheet: View {
    @ObservedObject var state: LingShuState
    let channelKey: String
    let title: String
    let dismiss: () -> Void

    @State private var name: String
    @State private var endpoint: String
    @State private var model: String
    @State private var secret: String = ""

    init(state: LingShuState, channelKey: String, title: String, defaultEndpoint: String, defaultModel: String, dismiss: @escaping () -> Void) {
        self.state = state; self.channelKey = channelKey; self.title = title; self.dismiss = dismiss
        let cfg = state.channelConfig(channelKey)
        _name = State(initialValue: cfg.name)
        _endpoint = State(initialValue: cfg.endpoint.isEmpty ? defaultEndpoint : cfg.endpoint)
        _model = State(initialValue: cfg.model.isEmpty ? defaultModel : cfg.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("配置 · \(title)").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.lingFg)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color.lingFg.opacity(0.5)) }.buttonStyle(.plain)
            }
            field("显示名(留空用默认)")
            TextField(title, text: $name).textFieldStyle(.roundedBorder)
            field("接口地址")
            TextField("https://…", text: $endpoint).textFieldStyle(.roundedBorder)
            field("模型 / 音色(可选)")
            TextField("如 deepseek-chat / qwen2.5-vl / male_steady", text: $model).textFieldStyle(.roundedBorder)
            field("访问密钥(不返显,留空保持不变)")
            SecureField("API Key / Token", text: $secret).textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.bordered)
                Button("保存") {
                    state.saveChannelConfig(channelKey, name: name, endpoint: endpoint, model: model, secret: secret)
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.lingVoid)
    }

    private func field(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.6))
    }
}

struct LingShuConfigLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.lingFg.opacity(0.48))
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.78))
                .lineLimit(2)
            Spacer()
        }
        .padding(10)
        .background(Color.lingFg.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
