import SwiftUI

struct LingShuExecutionConsoleView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("底层执行窗", systemImage: "terminal")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.lingHolo)

                Text(state.hasActiveModelCall ? "实时跟踪中" : "最近轨迹")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.hasActiveModelCall ? Color.lingHolo.opacity(0.86) : .white.opacity(0.42))

                Spacer()

                Text("\(state.executionTrace.count) 条")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))

                Button {
                    state.isExecutionConsoleExpanded.toggle()
                } label: {
                    Image(systemName: state.isExecutionConsoleExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.66))
                        .frame(width: 28, height: 24)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(state.isExecutionConsoleExpanded ? "收起底层执行窗" : "展开底层执行窗")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.black.opacity(0.24))

            if state.isExecutionConsoleExpanded {
                Divider()
                    .overlay(Color.lingHolo.opacity(0.14))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            if state.executionTrace.isEmpty {
                                Text("待机中。下一道指令开始后，这里会显示灵枢的具体执行轨迹。")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.46))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(state.executionTrace) { event in
                                    LingShuTraceEventRow(event: event)
                                        .id(event.id)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: state.executionTrace.count) { _, _ in
                        guard let lastID = state.executionTrace.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.lingHolo.opacity(state.hasActiveModelCall ? 0.32 : 0.16))
        }
    }
}

struct LingShuTraceEventRow: View {
    let event: ExecutionTraceEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: event.kind.icon)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(event.kind.color)
                .frame(width: 20, height: 20)
                .background(event.kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(event.displayTime)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
                .frame(width: 52, alignment: .leading)

            Text(event.actor)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(event.kind.color.opacity(0.92))
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)

                    if event.isStream {
                        Text("stream")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.lingHolo.opacity(0.78))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.lingHolo.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }

                Text(event.detail)
                    .font(.system(size: 11, weight: .medium, design: event.isStream ? .monospaced : .default))
                    .foregroundStyle(.white.opacity(event.isStream ? 0.54 : 0.62))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
