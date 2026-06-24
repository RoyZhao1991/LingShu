import SwiftUI

/// 「演示与答疑」的**「文本即进度条」UI**:把演示脚本画成一条进度条——每页一格,
/// 已念=实心、当前=高亮、未念=灰;**点任意格=拖到那页继续(视频流式)**。下方显示当前讲稿。
/// 演示进行/暂停/待确认下一篇时显示;闲置/结束时隐藏。挂在演示窗底部(见 LingShuPreviewSheet)。
struct LingShuPresentationProgressBar: View {
    @ObservedObject var presentation: LingShuPresentationController

    var body: some View {
        if presentation.isActive, let script = presentation.queue.currentScript, script.beatCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(phaseColor).frame(width: 7, height: 7)
                    Text(phaseLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    let pos = presentation.queue.position
                    let page = script.currentBeat?.pageNumber ?? script.beatCount
                    Text("\(script.title) · 第 \(pos.current)/\(pos.total) 篇 · 第 \(page)/\(script.beatCount) 页")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                // 进度条 = 脚本(每页一格,可点跳转)。这就是「演示稿文本本身即进度条」。
                HStack(spacing: 2) {
                    ForEach(Array(script.beats.enumerated()), id: \.offset) { i, _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(fill(forBeat: i, playhead: script.playhead))
                            .frame(height: 7)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await presentation.seekAndContinue(toBeat: i) } }
                            .help("跳到第 \(i + 1) 页继续")
                    }
                }

                if let narration = script.currentBeat?.narration, !narration.isEmpty {
                    Text(narration).font(.callout).foregroundStyle(.primary)
                        .lineLimit(2).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func fill(forBeat i: Int, playhead: Int) -> Color {
        if i < playhead { return .accentColor }               // 已念
        if i == playhead { return .accentColor.opacity(0.55) } // 当前
        return .gray.opacity(0.22)                             // 未念
    }

    private var phaseLabel: String {
        switch presentation.phase {
        case .idle: return "待命"
        case .scripting: return "正在通读 · 生成讲稿"
        case .playing: return "演示中"
        case .pausedForQA: return "答疑中（答完接着讲）"
        case .awaitingNextDoc: return "本篇演完 · 说「继续」切下一篇"
        case .finished: return "已结束"
        }
    }

    private var phaseColor: Color {
        switch presentation.phase {
        case .playing: return .green
        case .pausedForQA: return .orange
        case .scripting: return .blue
        case .awaitingNextDoc: return .yellow
        default: return .gray
        }
    }
}
