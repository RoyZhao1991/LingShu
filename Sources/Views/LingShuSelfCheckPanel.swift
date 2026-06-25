import SwiftUI

/// **自检面板**(配置 > 自检):展示灵枢**掌握的自己**——整体架构(分层设计)+ 实时能力(当前大脑/工具/agent插件/技能/记忆/感知/运行态)。
/// 数据来自 `assembleSelfInspection()`(每次打开实时拼装);大脑也能经 `self_inspect` 工具拉同一份自我认知。
struct LingShuSelfCheckPanel: View {
    @ObservedObject var state: LingShuState
    @State private var snapshot: LingShuSelfInspection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "scope").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.lingHolo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("自检 · 灵枢掌握的自己").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.92))
                    Text("整体架构 + 实时能力——大脑也经 self_inspect 工具拉同一份自我认知,用于答自指/规划/自进化")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
                Button { snapshot = state.assembleSelfInspection() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).help("刷新自检")
            }

            if let snap = snapshot {
                Text(snap.oneLiner)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lingHolo.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                groupHeader("整体架构", "灵枢是怎么搭的(相对稳定)")
                ForEach(Array(snap.architecture.enumerated()), id: \.offset) { _, s in sectionCard(s, accent: Color.lingHolo) }

                groupHeader("当前能力(实时)", "此刻具体有什么")
                ForEach(Array(snap.capabilities.enumerated()), id: \.offset) { _, s in sectionCard(s, accent: .green) }
            }
        }
        .onAppear { snapshot = state.assembleSelfInspection() }
    }

    @ViewBuilder private func groupHeader(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 6)
    }

    private func sectionCard(_ s: LingShuSelfInspection.Section, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(accent.opacity(0.95))
            ForEach(Array(s.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(accent.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 6)
                    Text(item).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(accent.opacity(0.18), lineWidth: 1))
    }
}
