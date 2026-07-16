import SwiftUI

// 跨界面复用的小型展示组件。从已删除的旧界面文件中抽出，供对话/运行态/配置等活跃表面共用。

/// 区块标题：图标 + 标题 + 副标题。
struct SectionHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.lingAccent)
                .frame(width: 30, height: 30)
                .background(Color.lingAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.system(size: 11.8, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
    }
}

/// 一行实时读数：图标 + 标签（字面）+ 数值（底层服务状态）。
struct HoloMetricRow: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = .lingHolo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.54))
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(0.88))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: 190, alignment: .trailing)
        }
    }
}

/// 一条巡检事件行：轮次 + agent/标题 + 详情。
struct SupervisorChainEventRow: View {
    let event: SupervisorEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(LingShuLanguagePreferenceStore.localized("巡检\(event.tick)", "Check \(event.tick)"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(event.severity.eventColor)
                Text("\(event.agent) / \(event.title)")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.lingFg.opacity(0.82))
                    .lineLimit(1)
            }
            Text(event.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.52))
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

/// 等宽代码块。
struct CodeBlockView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.lingFg.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.lingInk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
