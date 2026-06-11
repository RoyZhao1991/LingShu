import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage
    @ObservedObject var state: LingShuState

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
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .center, spacing: 9) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(Color.lingHolo)
                                .frame(width: 16, height: 16, alignment: .leading)

                            // 流式片段一到就显示；还没有内容时只显示安静的“思考中…”。
                            Text(message.text.isEmpty ? "思考中…" : message.text)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(.white.opacity(message.text.isEmpty ? 0.5 : 0.88))
                                .fixedSize(horizontal: false, vertical: true)
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
                } else {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.white.opacity(message.isUser ? 0.94 : 0.88))
                        .fixedSize(horizontal: false, vertical: true)
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
                Rectangle()
                    .fill(message.isUser ? Color.lingHolo.opacity(0.85) : Color.lingHoloAlt.opacity(0.6))
                    .frame(width: 2)
                    .shadow(color: (message.isUser ? Color.lingHolo : Color.lingHoloAlt).opacity(0.6), radius: 3)
            }
            .overlay {
                Rectangle()
                    .stroke(message.isUser ? Color.lingHolo.opacity(0.22) : Color.white.opacity(0.08), lineWidth: 0.8)
            }

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}
