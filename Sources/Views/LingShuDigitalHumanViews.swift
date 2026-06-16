import SwiftUI

struct LingShuDigitalHumanMiniOrb: View {
    let snapshot: LingShuDigitalHumanSnapshot
    /// 真实音频输出电平(0–1):驱动发声特效。有声才有,无声归零——与音频卡顿同步。
    var audioLevel: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            MiniOrbStack(snapshot: snapshot, now: timeline.date.timeIntervalSinceReferenceDate, audioLevel: audioLevel)
        }
        .help("灵枢：\(snapshot.expression.displayName) · \(snapshot.displayText)")
        .accessibilityLabel("灵枢，\(snapshot.expression.displayName)")
    }
}

/// mini 光球的 ZStack 整体抽成独立子视图——内联在 TimelineView 闭包里时编译器类型检查超时。渲染不变。
private struct MiniOrbStack: View {
    let snapshot: LingShuDigitalHumanSnapshot
    let now: Double
    var audioLevel: Double = 0

    var body: some View {
        // 发声特效改由**真实音频电平**驱动(voiceActive/level),不再用逻辑 signalIsActive(.mouth)——音频卡顿/断续时同步无特效。
        let level: Double = min(max(audioLevel, 0), 1)
        let voiceActive: Bool = level > 0.04
        let pulse = 0.5 + 0.5 * sin(now * (1.6 + snapshot.intensity * 2.2))
        let ringBoost: Double = voiceActive ? 0.28 : 0.0
        let ringOpacity: Double = 0.45 + 0.45 * snapshot.intensity + ringBoost + 0.25 * level
        let glowBase: Double = 4.0 + 9.0 * snapshot.intensity
        let glowDynamic: Double = 5.0 * pulse + 14.0 * level
        let glow = CGFloat(glowBase + glowDynamic)
        let angle: Double = now * 54
        return ZStack {
            Circle()
                .fill(Color.black.opacity(0.68))

            Circle()
                .stroke(snapshot.accent.opacity(voiceActive ? 0.24 : 0.14), lineWidth: 7)
                .blur(radius: 1.2)

            MiniOrbRotatingRing(accent: snapshot.accent, ringOpacity: ringOpacity, glow: glow, angle: angle)

            LingShuDigitalHumanOrbView(snapshot: snapshot, compact: true, audioLevel: audioLevel)
                .padding(7)

            MiniOrbSignalDots(snapshot: snapshot)
                .padding(4)

            if voiceActive {
                MiniOrbAudioPulse(accent: snapshot.accent, level: level)
            }

            Circle()
                .fill(snapshot.accent)
                .frame(width: 6.5, height: 6.5)
                .shadow(color: snapshot.accent.opacity(0.9), radius: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(5)
        }
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        }
    }
}

/// 旋转扫光环:从主 body 抽出(原内联表达式让编译器类型检查超时)。渲染不变。
private struct MiniOrbRotatingRing: View {
    let accent: Color
    let ringOpacity: Double
    let glow: CGFloat
    let angle: Double

    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [
                        accent.opacity(0.08),
                        accent.opacity(ringOpacity),
                        .white.opacity(0.82),
                        accent.opacity(ringOpacity),
                        accent.opacity(0.08)
                    ],
                    center: .center,
                    angle: .degrees(angle)
                ),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
            .shadow(color: accent.opacity(0.55), radius: glow)
    }
}

private struct MiniOrbSignalDots: View {
    let snapshot: LingShuDigitalHumanSnapshot

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size * 0.46
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

            ForEach(LingShuDigitalHumanSignal.allCases) { signal in
                let index = LingShuDigitalHumanSignal.allCases.firstIndex(of: signal) ?? 0
                let angle = Double(index) / Double(LingShuDigitalHumanSignal.allCases.count) * 2 * .pi - .pi / 2
                let active = snapshot.signalIsActive(signal)

                Circle()
                    .fill(active ? snapshot.accent : Color.white.opacity(0.18))
                    .frame(width: active ? 4.5 : 3.2, height: active ? 4.5 : 3.2)
                    .shadow(color: active ? snapshot.accent.opacity(0.8) : .clear, radius: 4)
                    .position(
                        x: center.x + CGFloat(cos(angle)) * radius,
                        y: center.y + CGFloat(sin(angle)) * radius
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MiniOrbAudioPulse: View {
    let accent: Color
    var level: Double = 0.5   // 真实音频电平(0–1):决定外圈音波的振幅与亮度

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.43
                let lvl = min(max(level, 0), 1)
                let amp = 0.05 + 0.16 * lvl   // 振幅随电平
                let bars = 18

                for index in 0..<bars {
                    let angle = Double(index) / Double(bars) * 2 * .pi - .pi / 2
                    let wave = 0.45 + 0.55 * abs(sin(t * 10 + Double(index) * 0.72))
                    let inner = radius * (0.76 + 0.03 * wave)
                    let outer = radius * (0.84 + amp * wave)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                    context.stroke(path, with: .color(accent.opacity(0.18 + 0.5 * lvl * wave)), lineWidth: 1.1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 纯表现组件：不订阅任何全局对象，避免动画驱动重渲业务视图。
struct LingShuDigitalHumanOrbView: View {
    let snapshot: LingShuDigitalHumanSnapshot
    var compact = false
    /// 真实音频输出电平(0–1):驱动中心圆脉冲扩缩 + 发声音波。有声才有,无声归零(与音频卡顿同步)。
    var audioLevel: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let intensity = CGFloat(min(max(snapshot.intensity, 0.08), 1))
                let level = CGFloat(min(max(audioLevel, 0), 1))
                let accent = snapshot.accent
                let pulse = CGFloat(0.5 + 0.5 * sin(t * (1.0 + snapshot.intensity * 3.0)))
                let warning = snapshot.expression == .alert

                drawGlow(context, center: center, radius: radius, accent: accent, pulse: pulse, intensity: intensity, level: level)
                drawCore(context, center: center, radius: radius, accent: accent, pulse: pulse, intensity: intensity, level: level)
                drawRings(context, center: center, radius: radius, accent: accent, t: t, intensity: intensity, warning: warning)
                drawSignalNodes(context, center: center, radius: radius, accent: accent, t: t)
                drawVoiceHalo(context, center: center, radius: radius, accent: accent, t: t, level: level)
            }
        }
        .drawingGroup()
    }

    private func drawGlow(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        accent: Color,
        pulse: CGFloat,
        intensity: CGFloat,
        level: CGFloat
    ) {
        let glowRadius = radius * (0.55 + 0.17 * pulse + 0.08 * intensity + 0.22 * level)
        let glow = Gradient(stops: [
            .init(color: accent.opacity(Double(0.52 + 0.28 * intensity + 0.25 * level)), location: 0),
            .init(color: accent.opacity(0.14), location: 0.52),
            .init(color: .clear, location: 1)
        ])
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - glowRadius,
                y: center.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )),
            with: .radialGradient(glow, center: center, startRadius: 0, endRadius: glowRadius)
        )
    }

    private func drawCore(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        accent: Color,
        pulse: CGFloat,
        intensity: CGFloat,
        level: CGFloat
    ) {
        // 中心圆半径由真实音频电平驱动:有声随振幅扩缩(脉冲),无声回基线 + 极弱呼吸。
        let idleBreath = 0.03 * pulse * (1 - level)
        let orbRadius = radius * (0.24 + 0.42 * level + idleBreath)
        let coreGradient = Gradient(stops: [
            .init(color: .white.opacity(0.92), location: 0),
            .init(color: accent.opacity(0.75), location: 0.34),
            .init(color: accent.opacity(0.16), location: 0.78),
            .init(color: .clear, location: 1)
        ])
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - orbRadius,
                y: center.y - orbRadius,
                width: orbRadius * 2,
                height: orbRadius * 2
            )),
            with: .radialGradient(coreGradient, center: center, startRadius: 0, endRadius: orbRadius)
        )

        let seed = radius * (0.035 + 0.02 * intensity + 0.05 * level)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - seed, y: center.y - seed, width: seed * 2, height: seed * 2)),
            with: .color(.white.opacity(0.96))
        )
    }

    private func drawRings(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        accent: Color,
        t: TimeInterval,
        intensity: CGFloat,
        warning: Bool
    ) {
        let speed = 0.55 + Double(intensity) * 1.65
        drawArcRing(context, center: center, radius: radius * 0.54, lineWidth: 2.4, rotation: t * speed, accent: accent.opacity(0.82))
        drawArcRing(context, center: center, radius: radius * 0.72, lineWidth: 1.35, rotation: -t * speed * 0.62, accent: accent.opacity(0.44))
        drawArcRing(context, center: center, radius: radius * 0.88, lineWidth: warning ? 2.2 : 1.1, rotation: t * speed * 0.32, accent: (warning ? Color.red : accent).opacity(warning ? 0.74 : 0.25))

        var orbit = Path()
        orbit.addEllipse(in: CGRect(
            x: center.x - radius * 0.94,
            y: center.y - radius * 0.94,
            width: radius * 1.88,
            height: radius * 1.88
        ))
        context.stroke(orbit, with: .color(accent.opacity(0.16)), lineWidth: 0.8)
    }

    private func drawArcRing(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        rotation: Double,
        accent: Color
    ) {
        for segment in [(0.03, 0.22), (0.38, 0.17), (0.68, 0.26)] {
            var path = Path()
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(segment.0 * 2 * .pi + rotation),
                endAngle: .radians((segment.0 + segment.1) * 2 * .pi + rotation),
                clockwise: false
            )
            context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    private func drawSignalNodes(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        accent: Color,
        t: TimeInterval
    ) {
        let signals = LingShuDigitalHumanSignal.allCases
        for index in signals.indices {
            let signal = signals[index]
            let angle = Double(index) / Double(signals.count) * 2 * .pi - .pi / 2
            let active = snapshot.signalIsActive(signal)
            let nodeRadius = radius * (active ? 0.036 : 0.024)
            let orbit = radius * 0.98
            let point = CGPoint(x: center.x + cos(angle) * orbit, y: center.y + sin(angle) * orbit)
            let flicker = 0.62 + 0.38 * abs(sin(t * 4 + Double(index)))
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - nodeRadius, y: point.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2)),
                with: .color((active ? accent : Color.white).opacity(active ? flicker : 0.18))
            )
        }
    }

    private func drawVoiceHalo(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        accent: Color,
        t: TimeInterval,
        level: CGFloat
    ) {
        guard level > 0.04 else { return }   // 有真实音频才画音波,无声不画(与卡顿同步)
        let lvl = Double(level)
        let bars = 36
        for index in 0..<bars {
            let angle = Double(index) / Double(bars) * 2 * .pi - .pi / 2
            let wave = 0.5 + 0.5 * sin(t * 8 + Double(index) * 0.8)
            let inner = radius * (1.05 + 0.02 * wave)
            let outer = radius * (1.06 + CGFloat(0.04 + 0.18 * lvl) * CGFloat(wave))   // 振幅随电平
            var path = Path()
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            context.stroke(path, with: .color(accent.opacity(0.2 + 0.55 * lvl * wave)), lineWidth: 1.2)
        }
    }
}
