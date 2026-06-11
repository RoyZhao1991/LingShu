import SwiftUI

// MARK: - 全息核心（弧光反应堆）

/// 灵枢的可视化核心：同心旋转弧环 + 呼吸辉光 + 刻度环。
/// 完全由 TimelineView 驱动，不订阅全局状态对象；活动强度只通过参数注入，
/// 因此核心动画永远不会触发界面级失效。
struct LingShuHoloCoreView: View {
    var color: Color
    /// 0 = 待机呼吸，1 = 全速运转
    var intensity: Double
    var isAbnormal: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let speed = 0.25 + intensity * 1.4
                let pulse = 0.5 + 0.5 * sin(t * (1.2 + intensity * 2.4))

                // 呼吸辉光底盘
                let glowRadius = radius * (0.46 + 0.07 * pulse)
                let glow = Gradient(stops: [
                    .init(color: color.opacity(0.55 + 0.25 * pulse), location: 0),
                    .init(color: color.opacity(0.12), location: 0.55),
                    .init(color: .clear, location: 1)
                ])
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - glowRadius, y: center.y - glowRadius,
                        width: glowRadius * 2, height: glowRadius * 2
                    )),
                    with: .radialGradient(glow, center: center, startRadius: 0, endRadius: glowRadius)
                )

                // 内核实心点
                let coreRadius = radius * 0.075 * (1 + 0.25 * pulse)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - coreRadius, y: center.y - coreRadius,
                        width: coreRadius * 2, height: coreRadius * 2
                    )),
                    with: .color(color.opacity(0.95))
                )

                // 旋转弧环（三层，速度与方向各异）
                drawArcRing(context, center: center, radius: radius * 0.58,
                            lineWidth: 2.2, segments: [(0, 0.32), (0.45, 0.18), (0.72, 0.12)],
                            rotation: t * speed, color: color.opacity(0.85))
                drawArcRing(context, center: center, radius: radius * 0.72,
                            lineWidth: 1.2, segments: [(0.1, 0.5), (0.68, 0.22)],
                            rotation: -t * speed * 0.6, color: color.opacity(0.45))
                drawArcRing(context, center: center, radius: radius * 0.42,
                            lineWidth: 3.4, segments: [(0.2, 0.16), (0.6, 0.16)],
                            rotation: t * speed * 1.7, color: color.opacity(0.65))

                // 外刻度环
                drawTickRing(context, center: center, radius: radius * 0.9,
                             ticks: 72, color: color.opacity(isAbnormal ? (0.2 + 0.5 * pulse) : 0.28),
                             highlightPhase: t * speed * 0.5)

                // 静态细圆
                var thinCircle = Path()
                thinCircle.addEllipse(in: CGRect(
                    x: center.x - radius * 0.82, y: center.y - radius * 0.82,
                    width: radius * 1.64, height: radius * 1.64
                ))
                context.stroke(thinCircle, with: .color(color.opacity(0.18)), lineWidth: 0.8)
            }
        }
        .drawingGroup()
    }

    private func drawArcRing(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        segments: [(start: Double, length: Double)],
        rotation: Double,
        color: Color
    ) {
        for segment in segments {
            var path = Path()
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(segment.start * 2 * .pi + rotation),
                endAngle: .radians((segment.start + segment.length) * 2 * .pi + rotation),
                clockwise: false
            )
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    private func drawTickRing(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        ticks: Int,
        color: Color,
        highlightPhase: Double
    ) {
        let highlightIndex = Int((highlightPhase.truncatingRemainder(dividingBy: 1)) * Double(ticks))
        for index in 0..<ticks {
            let angle = Double(index) / Double(ticks) * 2 * .pi - .pi / 2
            let isMajor = index % 6 == 0
            let isHighlight = (index + ticks - highlightIndex) % ticks < 4
            let inner = radius - (isMajor ? 7 : 4)
            var path = Path()
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            context.stroke(
                path,
                with: .color(isHighlight ? color.opacity(0.9) : color),
                lineWidth: isMajor ? 1.6 : 0.8
            )
        }
    }
}

// MARK: - HUD 面板（角框）

/// 全息 HUD 面板：极淡的填充、细描边和四角断开式角框，替代传统圆角卡片。
struct LingShuHUDPanel: ViewModifier {
    var accent: Color = .lingHolo
    var cornerLength: CGFloat = 14
    var fillOpacity: Double = 0.045

    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(fillOpacity))
            .background(.ultraThinMaterial.opacity(0.25))
            .overlay { LingShuHUDCorners(accent: accent, cornerLength: cornerLength) }
            .overlay {
                Rectangle()
                    .stroke(accent.opacity(0.14), lineWidth: 0.8)
            }
            .clipShape(Rectangle())
    }
}

struct LingShuHUDCorners: View {
    var accent: Color
    var cornerLength: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let l = cornerLength
            Path { p in
                // 左上
                p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: l, y: 0))
                // 右上
                p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
                // 右下
                p.move(to: CGPoint(x: w, y: h - l)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w - l, y: h))
                // 左下
                p.move(to: CGPoint(x: l, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: h - l))
            }
            .stroke(accent.opacity(0.65), lineWidth: 1.4)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func lingShuHUDPanel(accent: Color = .lingHolo, cornerLength: CGFloat = 14, fillOpacity: Double = 0.045) -> some View {
        modifier(LingShuHUDPanel(accent: accent, cornerLength: cornerLength, fillOpacity: fillOpacity))
    }
}

// MARK: - HUD 背景

/// 深空背景。顶部环境辉光的颜色跟随中枢状态（待机青 / 思考与执行各异 / 异常红），
/// 是状态的环境光指示，不是装饰；底部压暗渐变保证文字可读性。
struct LingShuHUDBackground: View {
    var accent: Color = .lingHolo

    var body: some View {
        ZStack {
            Color.lingVoid

            RadialGradient(
                colors: [accent.opacity(0.10), .clear],
                center: .init(x: 0.5, y: 0.12),
                startRadius: 10,
                endRadius: 620
            )
            .animation(.easeInOut(duration: 0.8), value: accent)

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 语音波形

/// 监听/播报时的迷你波形条，由 TimelineView 驱动。
struct LingShuVoiceWaveView: View {
    var color: Color = .lingHolo
    var isActive: Bool
    var barCount: Int = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = t * 7 + Double(index) * 1.1
                    let height: CGFloat = isActive ? 4 + 10 * abs(sin(phase)) : 3
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(isActive ? 0.9 : 0.3))
                        .frame(width: 2.5, height: height)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - 双层信息单元

/// 双层信息单元：第一层是字面文本（label/value），第二层是底层服务状态
/// （状态点颜色 + 状态词 + 可选的量化负载条）。界面里禁止出现没有第二层的纯说明文本。
struct LingShuDualLayerCell: View {
    let label: String
    let value: String
    /// 底层服务状态词，例如「在线」「执行中」「失联」「未接入」。
    let stateText: String
    let stateColor: Color
    /// 可选量化负载 0...1（链路负载、成熟度、占用等），nil 则不画条。
    var load: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: stateColor.opacity(0.8), radius: 3)
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 4)
                Text(stateText)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(stateColor.opacity(0.95))
            }

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let load {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(stateColor.opacity(0.7))
                            .frame(width: max(2, geo.size.width * min(max(load, 0), 1)))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(11)
        .lingShuHUDPanel(accent: stateColor, cornerLength: 7, fillOpacity: 0.04)
    }
}

// MARK: - HUD 读数

/// 等宽大写小标签 + 数值的 HUD 读数样式。
struct LingShuHUDReadout: View {
    let label: String
    let value: String
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color.opacity(0.94))
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }
}
