import SwiftUI

/// 灵枢请用户在有限选项中做选择时的选择卡片（对话内嵌）。选过之后置为已解决态，不再可点。
struct LingShuChoiceCard: View {
    let prompt: LingShuRouteChoicePrompt
    let resolvedChoice: String?
    let onSelect: (LingShuRouteChoiceOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 不再在卡片里重渲染 question:它的内容已经在消息正文(message.text,走 LingShuMessageContentView
            // 完整 Markdown 渲染)里完整呈现。卡片只放**可点击选项按钮**——否则会把带表格/加粗的正文用纯 Text
            // 平铺出来(换行被 parse 的 joined(" ") 压没),格式全乱、还和正文重复(用户实测投屏回复格式错乱的真因)。
            ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                let isResolved = resolvedChoice != nil
                let isPicked = resolvedChoice == option.label
                Button {
                    onSelect(option)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(isPicked ? Color.lingVoid : Color.lingHolo.opacity(0.8))
                            .frame(width: 20, height: 20)
                            .background(
                                isPicked ? Color.lingHolo : Color.lingHolo.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.lingFg.opacity(isResolved && !isPicked ? 0.4 : 0.92))
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = option.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.lingFg.opacity(isResolved && !isPicked ? 0.28 : 0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 4)
                        if isPicked {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.lingHolo)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isPicked ? Color.lingHolo.opacity(0.12) : Color.lingFg.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isPicked ? Color.lingHolo.opacity(0.45) : Color.lingFg.opacity(0.08))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isResolved)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: 460, alignment: .leading)
    }
}
