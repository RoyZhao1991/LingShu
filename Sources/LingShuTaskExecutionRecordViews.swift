import SwiftUI

struct TaskExecutionRecordSheet: View {
    let record: LingShuTaskExecutionRecord
    let lineageRecords: [LingShuTaskExecutionRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                    .frame(width: 42, height: 42)
                    .background(Color.lingHolo.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(record.status.rawValue)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(record.status.color)
                        Text("\(record.participants.count) 个参与方")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.52))
                        Text(record.updatedAt.taskRecordDisplayTime)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .background(Color.black.opacity(0.72))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !lineageRecords.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.lingHolo)
                                    Text("续接历史流程")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.92))
                                    Text("\(lineageRecords.count) 段")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.42))
                                }

                                ForEach(lineageRecords) { historicalRecord in
                                    TaskExecutionRecordHistoryBlock(record: historicalRecord)
                                }
                            }

                            Divider()
                                .overlay(Color.white.opacity(0.12))
                                .padding(.vertical, 4)

                            HStack(spacing: 8) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.lingHolo)
                                Text("本轮执行")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("任务摘要")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.lingHolo.opacity(0.88))
                            Text(record.summary)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.64))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        if !record.artifacts.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "shippingbox.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.lingHolo)
                                    Text("产出物")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.92))
                                    Text("\(record.artifacts.count) 项")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.42))
                                }

                                ForEach(record.artifacts) { artifact in
                                    TaskExecutionArtifactRow(artifact: artifact)
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.lingHolo.opacity(0.15))
                            }
                        }

                        ForEach(record.messages) { message in
                            TaskExecutionMessageRow(message: message)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("task-record-bottom")
                    }
                    .padding(18)
                }
                .onAppear {
                    proxy.scrollTo("task-record-bottom", anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(Color.lingVoid)
    }
}

struct TaskExecutionRecordHistoryBlock: View {
    let record: LingShuTaskExecutionRecord

    private var visibleMessages: [LingShuTaskExecutionMessage] {
        Array(record.messages.suffix(18))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(record.status.rawValue)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(record.status.color)
                Spacer()
                Text(record.updatedAt.taskRecordDisplayTime)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
            }

            Text(record.summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleMessages) { message in
                    TaskExecutionMessageRow(message: message)
                }
                if record.messages.count > visibleMessages.count {
                    Text("已折叠更早的 \(record.messages.count - visibleMessages.count) 条历史进度。")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.leading, 38)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.16))
        }
    }
}

struct TaskExecutionArtifactRow: View {
    let artifact: LingShuTaskExecutionArtifact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.lingHolo)
                .frame(width: 28, height: 28)
                .background(Color.lingHolo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(artifact.title)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(artifact.producer)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                    Text(artifact.createdAt.taskRecordDisplayTime)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
                }

                Text(artifact.location)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }
}

struct TaskExecutionMessageRow: View {
    let message: LingShuTaskExecutionMessage

    var body: some View {
        let isUser = message.kind == .user

        HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer(minLength: 90)
            } else {
                actorBadge
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if isUser { Spacer(minLength: 0) }
                    Text(message.actor)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(message.kind.color.opacity(0.94))
                    Text(message.role)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                    Text(message.timestamp.taskRecordDisplayTime)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
                }

                Text(message.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(isUser ? Color.lingHolo.opacity(0.20) : Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isUser ? Color.lingHolo.opacity(0.28) : message.kind.color.opacity(0.18))
                    }
            }
            .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 90)
            }
        }
    }

    private var actorBadge: some View {
        Image(systemName: message.kind.icon)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(message.kind.color)
            .frame(width: 28, height: 28)
            .background(message.kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
