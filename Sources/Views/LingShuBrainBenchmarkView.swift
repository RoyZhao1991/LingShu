import SwiftUI

/// 顶栏「脑力」可点 chip:点击弹出**具体评分** + 一键检测按钮(取代原来只读的 HUD readout)。
struct LingShuBrainScoreChip: View {
    @ObservedObject var state: LingShuState
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            LingShuHUDReadout(label: state.loc("脑力", "Brain"), value: "\(state.brainScore.score)", color: .lingHolo)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.loc("点击查看评分或一键检测脑力分", "View score details or run a benchmark"))
        .popover(isPresented: $show, arrowEdge: .bottom) {
            LingShuBrainScoreDetail(state: state).frame(width: 300)
        }
    }
}

/// 「脑力」点击后的具体评分浮层:当前脑 + 运行累计分拆解 + 上次测评分 + 一键检测按钮。
struct LingShuBrainScoreDetail: View {
    @ObservedObject var state: LingShuState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.loc("大脑评分", "Brain Score")).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.lingFg)
            Text(state.loc("当前脑 \(state.brainScore.brainID)", "Current brain \(state.brainScore.brainID)"))
                .font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.55))

            HStack(spacing: 10) {
                Text("\(state.brainScore.score)").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Color.lingHolo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.loc("运行累计分", "Runtime Score")).font(.system(size: 10)).foregroundStyle(Color.lingFg.opacity(0.4))
                    Text(state.loc(
                        "自主完成 +\(state.brainScore.completed) / 触发兜底 −\(state.brainScore.fallbacks)",
                        "Autonomous +\(state.brainScore.completed) / Fallbacks −\(state.brainScore.fallbacks)"
                    )).font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.75))
                }
            }
            if let b = state.brainBenchmarkResult {
                Divider().overlay(Color.lingFg.opacity(0.1))
                HStack(spacing: 8) {
                    Text(state.loc("上次测评", "Last Benchmark")).font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.5))
                    Text(state.loc("\(b.score) 分（\(b.grade)）", "\(b.score) points (\(b.grade))"))
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lingHolo)
                    Text(state.loc("通过 \(b.passedCount)/\(b.totalCount)", "Passed \(b.passedCount)/\(b.totalCount)"))
                        .font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.6))
                }
            }
            Button {
                Task { await state.runBrainBenchmark() }
            } label: {
                HStack(spacing: 6) {
                    if state.isRunningBrainBenchmark {
                        ProgressView().controlSize(.small).tint(Color.lingVoid)
                        Text(state.loc("检测中…（正在运行真实测试）", "Testing… (running real cases)"))
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Image(systemName: "brain.head.profile").font(.system(size: 12, weight: .semibold))
                        Text(state.loc("一键检测脑力分", "Run Brain Benchmark")).font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.lingVoid)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain).disabled(state.isRunningBrainBenchmark)
            Text(state.loc(
                "使用内置题库真实测试当前大脑并生成综合分，包含编码隐藏用例，耗时较长。更换大脑后可重新测评。",
                "Tests the current brain with built-in cases and hidden coding checks. This may take a while; rerun after switching brains."
            ))
                .font(.system(size: 10)).foregroundStyle(Color.lingFg.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.lingVoid)
    }
}

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
                        Text(state.loc("测评中…", "Benchmarking…")).font(.system(size: 12, weight: .semibold))
                    } else {
                        Image(systemName: "brain.head.profile").font(.system(size: 12, weight: .semibold))
                        Text(state.loc("运行脑力测试", "Run Brain Benchmark")).font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.lingVoid)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(state.isRunningBrainBenchmark)

            Text(state.loc(
                "通过算术、常识、推理和编码等不同难度题目测试当前大脑并生成综合分。更换大脑后可重新测评。",
                "Tests the current brain with arithmetic, knowledge, reasoning, and coding tasks across difficulty levels."
            ))
                .font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // 结果弹窗挂在根视图(LingShuRootView),不论当前在哪个界面跑完都弹。
    }
}

/// 脑力测评结果弹窗:大字综合分 + 评级 + 逐题通过情况 + 跨脑对比。
struct LingShuBrainBenchmarkResultView: View {
    let result: LingShuBrainBenchmarkResult
    var history: [LingShuBrainBenchmarkSnapshot] = []
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(loc("脑力测评", "Brain Benchmark")).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.lingFg)
                Spacer()
                Text(loc("当前脑 \(result.brainID)", "Current brain \(result.brainID)"))
                    .font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.55))
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(result.score)").font(.system(size: 46, weight: .heavy, design: .rounded)).foregroundStyle(Color.lingHolo)
                Text("/ 100").font(.system(size: 16)).foregroundStyle(Color.lingFg.opacity(0.5))
                Text(localizedBenchmarkLabel(result.grade)).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.lingVoid)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.lingHolo, in: Capsule())
                Spacer()
                Text(loc("通过 \(result.passedCount)/\(result.totalCount)", "Passed \(result.passedCount)/\(result.totalCount)"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.8))
            }

            // 按难度档的能力水位(易/中/难/极难 各档加权得分)——真正看出模型差距在哪一层
            if !result.tiers.isEmpty {
                HStack(spacing: 8) {
                    ForEach(result.tiers, id: \.label) { tier in
                        VStack(spacing: 2) {
                            Text(localizedBenchmarkLabel(tier.label)).font(.system(size: 10)).foregroundStyle(Color.lingFg.opacity(0.5))
                            Text("\(tier.pct)%").font(.system(size: 15, weight: .bold))
                                .foregroundStyle(tier.pct >= 90 ? Color.lingHolo : (tier.pct >= 60 ? .yellow : .orange))
                            Text("\(tier.passed)/\(tier.total)").font(.system(size: 9)).foregroundStyle(Color.lingFg.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            // 跨脑对比:测过多颗脑时并排比各档水位,差距在哪一层一目了然(换脑重测即累积)。
            if history.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("跨脑对比（各档水位）", "Cross-Brain Comparison"))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.85))
                    HStack(spacing: 0) {
                        Text(loc("脑", "Brain")).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(["综合", "易", "中", "难", "极难"], id: \.self) { h in
                            Text(localizedBenchmarkLabel(h)).frame(width: 44)
                        }
                    }.font(.system(size: 9)).foregroundStyle(Color.lingFg.opacity(0.4))
                    ForEach(history) { s in
                        HStack(spacing: 0) {
                            Text(s.brainID.split(separator: "|").first.map(String.init) ?? s.brainID)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(s.brainID == result.brainID ? Color.lingHolo : Color.lingFg.opacity(0.7))
                            Text("\(s.score)").frame(width: 44).foregroundStyle(Color.lingFg)
                            ForEach(["易","中","难","极难"], id: \.self) { tier in
                                let pct = s.tierPct(tier)
                                Text("\(pct)").frame(width: 44)
                                    .foregroundStyle(pct >= 90 ? Color.lingHolo : (pct >= 60 ? .yellow : .orange))
                            }
                        }.font(.system(size: 11, weight: .semibold))
                        .padding(.vertical, 3)
                    }
                }
                .padding(8)
                .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Divider().overlay(Color.lingFg.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: row.passed ? "checkmark.circle.fill" : (row.scoreText.isEmpty ? "xmark.circle.fill" : "circle.lefthalf.filled"))
                                .foregroundStyle(row.passed ? .green : (row.scoreText.isEmpty ? .orange : .yellow))
                                .font(.system(size: 13))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rowSummary(row)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.9))
                                Text(row.replyExcerpt).font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.45)).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            HStack {
                Spacer()
                Button(loc("关闭", "Close")) { onClose() }
                    .buttonStyle(.plain).foregroundStyle(Color.lingVoid)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(22)
        .background(Color.lingVoid)
    }

    private func loc(_ chinese: String, _ english: String) -> String {
        LingShuLanguagePreferenceStore.localized(chinese, english)
    }

    private func localizedBenchmarkLabel(_ value: String) -> String {
        guard LingShuLanguagePreferenceStore.currentLanguage() == .english else { return value }
        return [
            "综合": "Overall",
            "易": "Easy",
            "中": "Medium",
            "难": "Hard",
            "极难": "Extreme",
            "优秀": "Excellent",
            "良好": "Good",
            "合格": "Pass",
            "待提升": "Needs Work"
        ][value] ?? value
    }

    private func rowSummary(_ row: LingShuBrainBenchmarkResult.Row) -> String {
        let difficulty = loc("难度\(row.difficulty)", "Difficulty \(row.difficulty)")
        let agentic = row.agentic ? loc(" · 多步工具", " · Multi-step tools") : ""
        let score = row.scoreText.isEmpty ? "" : " · \(row.scoreText)"
        return "\(row.title) · \(difficulty)\(agentic)\(score)"
    }
}
