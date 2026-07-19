import SwiftUI

/// **自检面板**(配置 > 自检):展示灵枢**掌握的自己**——整体架构(分层设计)+ 实时能力(当前大脑/工具/agent插件/技能/记忆/感知/运行态)。
/// 数据来自 `assembleSelfInspection()`(每次打开实时拼装);大脑也能经 `self_inspect` 工具拉同一份自我认知。
struct LingShuSelfCheckPanel: View {
    @ObservedObject var state: LingShuState
    @State private var snapshot: LingShuSelfInspection?
    @State private var isRefreshingAgents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "scope").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.lingHolo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.loc("自检 · 灵枢掌握的自己", "Self-check · What Nous knows about itself"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.92))
                    Text(state.loc(
                        "整体架构 + 实时能力。大脑也经 self_inspect 工具读取同一份自我认知，用于自指回答、规划与自进化。",
                        "Architecture + live capabilities. The brain reads the same self-model through self_inspect for self-reference, planning, and evolution."
                    ))
                        .font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.45))
                }
                Spacer(minLength: 0)
                Button { refreshSnapshot(forceProbe: true) } label: {
                    HStack(spacing: 5) {
                        if isRefreshingAgents { ProgressView().controlSize(.mini) }
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lingFg.opacity(0.5))
                .help(state.loc("刷新自检并重新探活 Agent 插件", "Refresh self-check and probe Agent plugins"))
                .disabled(isRefreshingAgents)
            }

            if let snap = snapshot {
                Text(snap.oneLiner)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.85))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lingHolo.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                groupHeader(state.loc("整体架构", "Architecture"), state.loc("灵枢是怎么搭的（相对稳定）", "How Nous is built (relatively stable)"))
                ForEach(Array(snap.architecture.enumerated()), id: \.offset) { _, s in sectionCard(s, accent: Color.lingHolo) }

                groupHeader(state.loc("当前能力（实时）", "Current Capabilities (Live)"), state.loc("此刻具体有什么", "What is available right now"))
                ForEach(Array(snap.capabilities.enumerated()), id: \.offset) { _, s in sectionCard(s, accent: .green) }

                feedbackCard
            }
        }
        .onAppear { refreshSnapshot(forceProbe: state.agentPluginSelfInspectionNeedsRefresh()) }
    }

    private func refreshSnapshot(forceProbe: Bool) {
        snapshot = state.assembleSelfInspection()
        guard forceProbe, !isRefreshingAgents else { return }
        isRefreshingAgents = true
        Task { @MainActor in
            await state.refreshAgentPluginAvailabilityForSelfInspection()
            snapshot = state.assembleSelfInspection()
            isRefreshingAgents = false
        }
    }

    @ViewBuilder private func groupHeader(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
            Text(sub).font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.4))
        }
        .padding(.top, 6)
    }

    private func sectionCard(_ s: LingShuSelfInspection.Section, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(accent.opacity(0.95))
            ForEach(Array(s.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(accent.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 6)
                    Text(item).font(.system(size: 12)).foregroundStyle(Color.lingFg.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(accent.opacity(0.18), lineWidth: 1))
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                icon: "bubble.left.and.text.bubble.right",
                title: state.loc("Alpha 反馈与社区", "Alpha Feedback & Community"),
                subtitle: state.loc("报告真实首跑结果，或向社区提问", "Report a real first run or ask the community")
            )

            Text(state.loc(
                "无论首跑成功、部分成功还是失败，都欢迎提交不含凭据和私人数据的结构化报告。成功首跑只需填写关键结果，不必整理长日志。",
                "Whether the first run succeeds, partly succeeds, or fails, share a structured report without credentials or private data. A successful run only needs the key outcome fields, not a long log."
            ))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.lingFg.opacity(0.58))
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Link(destination: LingShuPublicLinks.firstRunReport(for: state.language)) {
                    Label(state.loc("提交首跑报告", "Share First-run Report"), systemImage: "checklist")
                }
                .buttonStyle(.borderedProminent)
                .tint(.lingHolo)

                Link(destination: LingShuPublicLinks.discussions) {
                    Label(state.loc("社区提问", "Ask the Community"), systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.bordered)

                Link(destination: LingShuPublicLinks.repository) {
                    Label(state.loc("查看源码", "View Source"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 11.5, weight: .semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.18)) }
    }
}
