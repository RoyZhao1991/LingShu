import SwiftUI
import AppKit

/// 外接设备感知配置页（配置 → 外接设备）。主开关 + 各模块启停/状态/配对 + 关键待办列表 + 隐私说明。
/// 文案走 `state.loc`。直接观察中枢 `LingShuExternalSensoryHub`（@Published 驱动刷新）。
struct LingShuExternalSensoryView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var hub: LingShuExternalSensoryHub

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                icon: "sensor.tag.radiowaves.forward",
                title: state.loc("外接设备感知", "External Devices"),
                subtitle: state.loc(
                    "手机通知 / 日历…独立模块汇聚成标准输入,与视觉/听觉一起交给大脑评判",
                    "Phone alerts / calendar… independent modules merged into one standard input for the brain"
                )
            )

            masterToggle
            if hub.masterEnabled {
                sourceList
                if !hub.phoneTodos.isEmpty { todoList }
            }
            privacyNote
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
        .alert(item: $hub.warning) { warning in
            Alert(
                title: Text(state.localizedRuntimeText(warning.title, fallback: state.loc("外接设备需要处理", "External Device Needs Attention"))),
                message: Text(state.localizedRuntimeText(warning.message, fallback: state.loc("请检查设备、系统权限或连接状态后重试。", "Check the device, system permissions, or connection, then try again."))),
                dismissButton: .default(Text(state.loc("知道了", "OK")))
            )
        }
    }

    private var masterToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: hub.masterEnabled ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(hub.masterEnabled ? Color.lingHolo : Color.lingFg.opacity(0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.loc("总开关", "Master switch"))
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
                Text(state.loc("默认关闭。开启后才会连任何外接设备", "Off by default. Connects devices only when on"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.45))
            }
            Spacer()
            Toggle("", isOn: Binding(get: { hub.masterEnabled }, set: { hub.setMasterEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(hub.availableSources, id: \.id) { descriptor in
                sourceRow(descriptor)
            }
        }
    }

    private func sourceRow(_ descriptor: LingShuExternalSensoryDescriptor) -> some View {
        let status = hub.status(for: descriptor.id)
        let enabled = hub.isEnabled(descriptor.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: descriptor.channel.icon)
                    .foregroundStyle(status.isActive ? Color.lingHolo : Color.lingFg.opacity(0.4))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.loc(descriptor.displayName, descriptor.englishName))
                        .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
                    Text(state.loc(descriptor.summary, descriptor.englishSummary))
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.45))
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { _ in hub.toggleSource(descriptor.id) }))
                    .toggleStyle(.switch).controlSize(.mini)
            }
            if enabled {
                HStack(alignment: .top, spacing: 6) {
                    statusDot(status).padding(.top, 4)
                    Text(statusLabel(status))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    if descriptor.requiresPairing, case .pairing = status {
                        Text(state.loc("· 请在 iPhone 上点「配对」", "· Confirm pairing on iPhone"))
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingHoloAlt)
                    }
                }
                if descriptor.requiresPairing {
                    HStack(spacing: 5) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 9.5))
                        Text(state.loc("对外广播蓝牙名：", "Bluetooth name: ") + "「\(state.appName)」")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.lingFg.opacity(0.4))
                }
                if descriptor.requiresPairing, case .unavailable = status {
                    pairingHelp(descriptor)
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 配对受阻时的可解释帮助:重试扫描 + 打开系统蓝牙设置 + 指向可用的兜底源。
    @ViewBuilder
    private func pairingHelp(_ descriptor: LingShuExternalSensoryDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    hub.retrySource(descriptor.id)
                } label: {
                    Label(state.loc("重试扫描", "Rescan"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(state.loc("打开系统蓝牙设置", "Open Bluetooth Settings"), systemImage: "gearshape")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Text(state.loc(
                "提示:iOS 不向第三方 Mac 应用开放 ANCS,纯 Mac 端读 iPhone 通知是 Apple 的已知限制。要立刻验证整条链路(汇聚→蒸馏→注入大脑),可改开下方「日历 + 提醒事项」——零配对、本地可用。",
                "Note: iOS doesn't expose ANCS to third-party Mac apps — reading iPhone notifications from a pure Mac app is an Apple limitation. To verify the full pipeline now, enable Calendar + Reminders below — no pairing, works locally."
            ))
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var todoList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.loc("关键待办", "Key to-dos"))
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.75))
            ForEach(hub.phoneTodos) { todo in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Color.lingHolo).font(.system(size: 11))
                        Text(todo.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.9))
                        Spacer()
                        if let due = todo.due {
                            Text(due).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.lingHoloAlt)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.lingFg.opacity(0.07), in: Capsule())
                        }
                    }
                    if !todo.actionSuggestion.isEmpty {
                        Text(todo.actionSuggestion).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.5))
                    }
                    Text("\(todo.sourceApp)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.35))
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            if !hub.lastNote.isEmpty {
                Text(state.localizedRuntimeText(hub.lastNote, fallback: state.loc("待办蒸馏已更新", "To-do distillation updated")))
                    .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.3))
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(Color.lingFg.opacity(0.4)).font(.system(size: 11))
            Text(state.loc(
                "全程本地 · 只读不回写 · 通知正文不落盘 · 关闭即清空内存。配对需在设备上显式确认。",
                "Fully local · read-only · message bodies never persisted · cleared on disable. Pairing needs on-device consent."
            ))
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.lingFg.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func statusDot(_ status: LingShuExternalSensoryStatus) -> some View {
        let color: Color = switch status {
        case .streaming: .green
        case .connecting, .pairing: .yellow
        case .unavailable: .red.opacity(0.7)
        case .disabled: Color.lingFg.opacity(0.25)
        }
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    private func statusLabel(_ status: LingShuExternalSensoryStatus) -> String {
        switch status {
        case .disabled: state.loc("未启用", "Disabled")
        case .connecting: state.loc("连接中", "Connecting")
        case .pairing: state.loc("等待配对确认", "Awaiting pairing")
        case .streaming: state.loc("接收中", "Streaming")
        case .unavailable(let reason):
            state.loc(
                "不可用：\(reason)",
                "Unavailable: \(state.localizedRuntimeText(reason, fallback: "Check permissions or hardware"))"
            )
        }
    }
}
