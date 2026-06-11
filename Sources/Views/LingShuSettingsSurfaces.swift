import SwiftUI

struct LingShuOperationsSurface: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(icon: "building.columns", title: "隐藏运维界面", subtitle: "能力池、调用链、审计与能力域")

                HStack(alignment: .top, spacing: 16) {
                    LingShuOpsCard(title: "治理链路", icon: "building.columns", lines: ["规划：任务草案", "审议：风险与权限", "调度：分派与汇总"])
                    LingShuOpsCard(title: "能力节点", icon: "hammer", lines: ["规划 / 审议 / 调度", "执行 / 监控 / 验证", "记忆 / 安全 / 知识"])
                    LingShuOpsCard(title: "运行策略", icon: "checkmark.shield", lines: ["灵枢统一回复", "节点只进调用链", "高风险人工确认"])
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("事件日志")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    ForEach(state.eventLog.prefix(10), id: \.self) { item in
                        Text(item)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(22)
        }
    }
}

struct LingShuOpsCard: View {
    let title: String
    let icon: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08))
        }
    }
}

struct LingShuModelGatewaySurface: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(icon: "slider.horizontal.3", title: "模型访问配置", subtitle: "Codex Auth + 国内外主流大模型 API + 本地模型")

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

                        Text("Fast 模式只切换 Codex 的推理强度和服务档位；执行不按总时长中断，只有连续失去心跳才进入异常。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                            .fixedSize(horizontal: false, vertical: true)

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

                        Text(state.selectedModelPreset?.note ?? "自定义模型网关。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
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
                                Text(preset.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
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
