import SwiftUI

/// 「脑力测试」入口条 + 结果弹窗:跑一套硬编码难度不等的题 → 综合评分 → 弹窗展示当前脑的脑力分。
struct LingShuBrainBenchmarkBar: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await state.runBrainBenchmark() }
            } label: {
                HStack(spacing: 6) {
                    if state.isRunningBrainBenchmark {
                        ProgressView().controlSize(.small).tint(Color.lingVoid)
                        Text("测评中…").font(.system(size: 12, weight: .semibold))
                    } else {
                        Image(systemName: "brain.head.profile").font(.system(size: 12, weight: .semibold))
                        Text("运行脑力测试").font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.lingVoid)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(state.isRunningBrainBenchmark)

            Text("跑一套难度不等的题(算术/常识/推理/编码…)测当前脑,出综合分。换大脑后可重测。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // 结果弹窗挂在根视图(LingShuRootView),不论当前在哪个界面跑完都弹。
    }
}

/// 脑力测评结果弹窗:大字综合分 + 评级 + 逐题通过情况。
struct LingShuBrainBenchmarkResultView: View {
    let result: LingShuBrainBenchmarkResult
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("脑力测评").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text("当前脑 \(result.brainID)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(result.score)").font(.system(size: 46, weight: .heavy, design: .rounded)).foregroundStyle(Color.lingHolo)
                Text("/ 100").font(.system(size: 16)).foregroundStyle(.white.opacity(0.5))
                Text(result.grade).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.lingVoid)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.lingHolo, in: Capsule())
                Spacer()
                Text("通过 \(result.passedCount)/\(result.totalCount)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }

            Divider().overlay(Color.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: row.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(row.passed ? .green : .orange)
                                .font(.system(size: 13))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(row.title) · 难度\(row.difficulty)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                                Text(row.replyExcerpt).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            HStack {
                Spacer()
                Button("关闭") { onClose() }
                    .buttonStyle(.plain).foregroundStyle(Color.lingVoid)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(22)
        .background(Color.lingVoid)
    }
}
