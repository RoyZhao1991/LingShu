import SwiftUI

/// 「已连接外设」面板——**薄壳**:只呈现给人看/确认的信息(灵枢发现了什么、是什么、接没接),**不放动作按钮**。
/// 灵枢是"人",接入/探测/控制都**直接对它说**(回到对话);这里只是一扇"发现 + 状态"的只读窗口。
struct LingShuPeripheralsView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var hub: LingShuPeripheralHub

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                icon: "cpu",
                title: state.loc("已连接外设", "Connected Peripherals"),
                subtitle: state.loc(
                    "灵枢自动发现并识别的设备一览。要接入/控制某个设备,直接对灵枢说(如「把床头灯接入」「开床头灯」)",
                    "What Nous discovered. To integrate or control one, just tell Nous in chat"
                )
            )
            scanBar
            if !hub.hint.isEmpty { hintRow }
            groupedList
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
        .onAppear { if hub.peripherals.count <= 1 { Task { await state.refreshPeripherals() } } }
    }

    private var scanBar: some View {
        HStack(spacing: 10) {
            Image(systemName: hub.scanning ? "dot.radiowaves.left.and.right" : "sensor.tag.radiowaves.forward")
                .foregroundStyle(hub.scanning ? Color.lingHolo : Color.lingFg.opacity(0.5))
            Text(hub.scanning ? state.loc("正在发现外设…", "Discovering…")
                              : state.loc("\(deviceCount) 台外设 · 大脑已识别", "\(deviceCount) peripherals · identified"))
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.85))
            Spacer()
            Button { Task { await state.refreshPeripherals() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.lingFg.opacity(0.7)).padding(6)
                    .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain).help(state.loc("重新发现", "Rescan"))
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var hintRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
            Text(state.localizedRuntimeText(hub.hint, fallback: state.loc("外设发现需要系统权限", "Peripheral discovery needs system permission")))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange.opacity(0.9))
            Spacer()
            Button { state.openLocalNetworkSettings() } label: {
                Text(state.loc("去开启", "Open Settings"))
                    .font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color.lingVoid)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 7).padding(.horizontal, 11)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 按归一键合并同一物理设备的多通道,能力取并集。
    private var devices: [LingShuPeripheral] {
        Dictionary(grouping: hub.peripherals) { $0.canonicalKey }.values.map { group -> LingShuPeripheral in
            var rep = group.first { $0.classification != nil } ?? group[0]
            let caps = Set(group.flatMap { $0.classification?.capabilities ?? [] })
            if !caps.isEmpty { rep.classification?.capabilities = Array(caps).sorted() }
            if group.contains(where: { $0.integrated }) { rep.integrated = true }
            return rep
        }
    }

    private var deviceCount: Int { devices.count }

    private var grouped: [(String, [LingShuPeripheral])] {
        Dictionary(grouping: devices) { localizedGroup($0) }
            .map { ($0.key, $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.0 < $1.0 }
    }

    private var groupedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(grouped, id: \.0) { group, items in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.55))
                    ForEach(items) { row($0) }
                }
            }
        }
    }

    /// 只读行:图标 + 别名(+原始名)+ 用途 + 能力 chips + 状态(无任何动作按钮)。
    private func row(_ p: LingShuPeripheral) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(p)).foregroundStyle(Color.lingFg.opacity(0.6)).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(localizedName(p)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.9))
                    if p.displayName != p.name {
                        Text(p.name).font(.system(size: 10)).foregroundStyle(Color.lingFg.opacity(0.35))
                    }
                }
                Text(localizedDetail(p))
                    .font(.system(size: 10.5)).foregroundStyle(Color.lingFg.opacity(0.45)).lineLimit(2)
                if let caps = p.classification?.capabilities, !caps.isEmpty {
                    HStack(spacing: 4) { ForEach(caps.prefix(5), id: \.self) { chip(localizedCapability($0)) } }
                }
            }
            Spacer()
            statusPill(p)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.6))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.lingFg.opacity(0.08), in: Capsule())
    }

    private func statusPill(_ p: LingShuPeripheral) -> some View {
        let (text, color): (String, Color) =
            p.isControllable ? (state.loc("已接入", "Integrated"), .lingHolo)
            : p.classification == nil ? (state.loc("待识别", "—"), Color.lingFg.opacity(0.45))
            : (p.classification!.integratable ? (state.loc("可接入", "Ready"), .lingHolo) : (state.loc("暂不可接入", "N/A"), .orange))
        return Text(text)
            .font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func icon(_ p: LingShuPeripheral) -> String {
        switch p.transport {
        case .network: "network"
        case .serial: "cable.connector"
        case .usb: "cable.connector.horizontal"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .power: "bolt.fill"
        case .sensor: "sensor.tag.radiowaves.forward"
        case .component: "puzzlepiece.extension.fill"
        case .local: "desktopcomputer"
        }
    }

    private func localizedGroup(_ p: LingShuPeripheral) -> String {
        guard state.language == .english else { return p.displayGroup }
        if p.classification?.deviceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return LingShuState.containsHan(p.displayGroup) ? "Identified Devices" : p.displayGroup
        }
        return p.transport.placeholderGroup.en
    }

    private func localizedName(_ p: LingShuPeripheral) -> String {
        guard state.language == .english else { return p.displayName }
        if p.id == "local.volume" { return "This Mac · System Volume" }
        return p.displayName
    }

    private func localizedDetail(_ p: LingShuPeripheral) -> String {
        let detail = (p.classification?.what).flatMap { $0.isEmpty ? nil : $0 } ?? p.statusLine
        guard state.language == .english else { return detail }
        if p.id == "local.volume" {
            let value = detail.split(separator: " ").last.map(String.init) ?? ""
            return value.isEmpty ? "System output volume" : "Current volume \(value)"
        }
        if detail.hasPrefix("局域网服务 ") {
            return "Local network service " + detail.dropFirst("局域网服务 ".count)
        }
        return LingShuState.containsHan(detail) ? "Discovered peripheral" : detail
    }

    private func localizedCapability(_ value: String) -> String {
        guard state.language == .english else { return value }
        let known = [
            "开关": "Power", "亮度": "Brightness", "色温": "Color Temperature",
            "音频输出": "Audio Output", "音频输入": "Audio Input", "音量": "Volume",
            "传感": "Sensing", "通知": "Notifications"
        ]
        return known[value] ?? (LingShuState.containsHan(value) ? "Capability" : value)
    }
}
