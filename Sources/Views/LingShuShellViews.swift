import AppKit
import SwiftUI

struct SidebarView: View {
    @Binding var selected: NavItem

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("灵枢")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("智能中枢")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .padding(.top, 18)

            VStack(spacing: 8) {
                ForEach(NavItem.allCases) { item in
                    Button {
                        selected = item
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 24)
                            Text(item.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                        }
                        .padding(.vertical, 11)
                        .padding(.horizontal, 12)
                        .foregroundStyle(selected == item ? Color.lingInk : .white.opacity(0.76))
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected == item ? Color.white : Color.white.opacity(0.06))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 9) {
                Label("macOS 原生入口", systemImage: "desktopcomputer")
                Label("智能体协作内核", systemImage: "network")
                Label("能力包起步", systemImage: "hammer")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.66))

            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 9, height: 9)
                Text("原型在线")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
        .frame(width: 214)
        .background(Color.lingSidebar)
    }
}

struct TopBarView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("灵枢")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(state.selectedSurface == .chat ? .white : Color.lingInk)
                Text("对话式 AI 中枢，后台按需调用能力节点。")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(state.selectedSurface == .chat ? .white.opacity(0.56) : Color.lingMuted)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            HStack(spacing: 6) {
                ForEach(AppSurface.allCases) { surface in
                    Button {
                        state.selectedSurface = surface
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: surface.icon)
                            Text(surface.rawValue)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .foregroundStyle(state.selectedSurface == surface ? Color.lingVoid : (state.selectedSurface == .chat ? .white.opacity(0.78) : Color.lingInk))
                        .background(state.selectedSurface == surface ? Color.lingHolo : (state.selectedSurface == .chat ? Color.white.opacity(0.07) : Color.white), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(state.selectedSurface == .chat ? Color.lingHolo.opacity(0.18) : Color.black.opacity(state.selectedSurface == surface ? 0 : 0.07))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            StatusPill(title: "当前阶段", value: state.activeLayer, icon: "cpu")
            StatusPill(title: "可信度", value: "\(state.trustScore)%", icon: "checkmark.seal")

            Button {
                state.startDemoMissionIfConnected()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(state.selectedSurface == .chat ? Color.lingVoid : .white)
                    .background(state.selectedSurface == .chat ? Color.lingHolo : Color.lingInk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("开始一次演示任务")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(state.selectedSurface == .chat ? Color.lingVoid.opacity(0.94) : .white.opacity(0.86))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(state.selectedSurface == .chat ? Color.lingHolo.opacity(0.20) : Color.black.opacity(0.07))
                .frame(height: 1)
        }
    }
}

struct StatusPill: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.lingFaint.opacity(0.85))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        }
    }
}
