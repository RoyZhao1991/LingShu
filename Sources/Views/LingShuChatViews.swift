import SwiftUI

/// 任务执行时主线程对话里的紧凑状态行：转圈 + 当前步骤名 + 实时耗时（秒）。
/// 主线程只报"在干什么、干了多久"（语音交互友好，不刷屏）；点一下进**任务子线程窗口**
/// 看一边执行一边汇报的多段过程（规划/产出/工具/评审/纠正…全程，与主线程互不干扰）。
struct LingShuTaskProgressIndicator: View {
    let stage: String
    let startedAt: Date
    var onOpen: (() -> Void)?

    var body: some View {
        Button {
            onOpen?()
        } label: {
            HStack(spacing: 9) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(Color.lingHolo)
                    .frame(width: 16, height: 16)
                Text(stage)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text("\(elapsed)s")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 8)
                if onOpen != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.split.2x1")
                        Text("查看执行过程")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.lingHolo.opacity(0.85))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .help("打开任务子线程窗口，实时查看多段执行过程")
    }
}

struct ChatBubbleView: View {
    let message: ChatMessage
    @ObservedObject var state: LingShuState
    /// 霓虹侧条的"呼吸"相位——轻微动效,看着更科幻(只动一根 2px 条 + 描边,开销极小)。
    @State private var glow = false

    private var accent: Color { message.isUser ? .lingHolo : .lingHoloAlt }

    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.isUser ? "你" : "灵枢")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(message.isUser ? .white.opacity(0.72) : Color.lingHolo.opacity(0.84))

                if message.isLoading && !message.isUser {
                    if message.taskRecordID != nil {
                        // 任务执行：主线程只显示「当前步骤 + 耗时」的紧凑状态（语音友好、不刷屏）；
                        // 点一下进任务子线程窗口看实时的多段执行过程——对齐 codex/claude 的状态行做法。
                        LingShuTaskProgressIndicator(stage: state.missionTitle, startedAt: message.createdAt) {
                            state.openTaskRecord(message.taskRecordID)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 9) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(Color.lingHolo)
                                    .frame(width: 16, height: 16, alignment: .leading)

                                // 直答通道：流式片段一到就分块显示；还没有内容时只显示安静的“思考中…”。
                                if message.text.isEmpty {
                                    Text("思考中…")
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.5))
                                } else {
                                    LingShuMessageContentView(text: message.text)
                                }
                            }

                            // 模型的实时推理预览：滚动展示思考流的尾部，定稿即消失。
                            if let thinking = message.thinkingPreview, !thinking.isEmpty {
                                Text(thinking)
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.38))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 25)
                                    .transition(.opacity)
                                    .animation(.easeInOut(duration: 0.2), value: thinking)
                            }
                        }
                    }
                } else if message.isUser {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    // 灵枢回复：结构化分块（代码块单独成卡片，正文走 Markdown）。
                    LingShuMessageContentView(text: message.text)
                        .textSelection(.enabled)
                }

                if !message.isUser, !message.isLoading, let choices = message.choices {
                    LingShuChoiceCard(
                        prompt: choices,
                        resolvedChoice: message.resolvedChoice
                    ) { option in
                        state.selectRouteChoice(option, for: message.id)
                    }
                }

                if !message.isUser,
                   !message.isLoading,
                   let taskRecordID = message.taskRecordID,
                   state.taskExecutionRecordLookup.contains(where: { $0.id == taskRecordID }) {
                    Button {
                        state.openTaskRecord(taskRecordID)
                    } label: {
                        Label("查看任务执行记录", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.lingHolo.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.lingHolo.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.lingHolo.opacity(0.18))
                            }
                    }
                    .buttonStyle(.plain)
                    .help("打开本轮任务的 agent 群聊式执行记录")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: message.isUser ? 420 : 760, alignment: .leading)
            .background(
                LinearGradient(
                    colors: message.isUser
                        ? [Color.lingHolo.opacity(0.16), Color.lingHolo.opacity(0.05)]
                        : [Color.white.opacity(0.06), Color.white.opacity(0.02)],
                    startPoint: message.isUser ? .topTrailing : .topLeading,
                    endPoint: message.isUser ? .bottomLeading : .bottomTrailing
                )
            )
            .overlay(alignment: message.isUser ? .trailing : .leading) {
                // 霓虹侧条:缓慢呼吸的辉光(opacity + shadow 在两值间往返),像"通电"的感觉。
                Rectangle()
                    .fill(accent.opacity(glow ? 0.95 : 0.55))
                    .frame(width: 2)
                    .shadow(color: accent.opacity(glow ? 0.85 : 0.3), radius: glow ? 6 : 2)
            }
            .overlay {
                // 描边也随呼吸极轻微地亮一下(克制,避免闪烁)。
                Rectangle()
                    .stroke((message.isUser ? Color.lingHolo : Color.white).opacity((message.isUser ? 0.22 : 0.08) + (glow ? 0.06 : 0)), lineWidth: 0.8)
            }

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}
