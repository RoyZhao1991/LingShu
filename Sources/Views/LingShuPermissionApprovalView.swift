import SwiftUI

/// 系统命令授权弹窗（中文）：灵枢要在本机执行高风险命令时，停在这里等用户裁决，
/// 而不是默默拒绝、逼模型降级成"给你段脚本自己跑"。对标 Codex/Claude Code 的批准弹窗。
struct LingShuPermissionApprovalView: View {
    let pending: LingShuPendingShellApproval
    let onDecision: (LingShuShellApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.riskNotes.isEmpty ? "灵枢 请求执行系统命令" : "⚠️ 灵枢 请求执行高风险来源脚本")
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(pending.riskNotes.isEmpty ? .white : Color.orange)
                    Text(pending.riskNotes.isEmpty ? "需要你授权才会在本机运行" : "自发现 skill 的脚本经风险审被标记,首次运行需你裁决")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            if !pending.riskNotes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("风险审提示")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange.opacity(0.9))
                    ForEach(Array(pending.riskNotes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 0.8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("命令")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHolo.opacity(0.8))
                ScrollView(.vertical, showsIndicators: true) {
                    Text(pending.command.isEmpty ? "（空命令）" : pending.command)
                        .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                }
                .frame(maxHeight: 120)
                .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                }

                Label(pending.workingDirectory, systemImage: "folder")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(spacing: 9) {
                approvalButton(
                    title: "本次允许",
                    subtitle: "只放行这一条命令",
                    icon: "checkmark.circle.fill",
                    tint: Color.lingHolo,
                    filled: true
                ) { onDecision(.allowOnce) }

                approvalButton(
                    title: "完全授权",
                    subtitle: "本次会话后续命令不再询问",
                    icon: "bolt.shield.fill",
                    tint: .orange,
                    filled: false
                ) { onDecision(.allowAlways) }

                approvalButton(
                    title: "拒绝",
                    subtitle: "不执行，灵枢改用其它方式",
                    icon: "xmark.circle.fill",
                    tint: .red,
                    filled: false
                ) { onDecision(.deny) }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color.lingVoid)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func approvalButton(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        filled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(filled ? Color.lingVoid : tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(filled ? Color.lingVoid : .white)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(filled ? Color.lingVoid.opacity(0.7) : .white.opacity(0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                filled ? tint : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(filled ? Color.clear : tint.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
