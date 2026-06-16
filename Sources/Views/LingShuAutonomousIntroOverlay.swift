import SwiftUI

/// 自主运行「进入仪式」(用户定调 2026-06-17,只增强仪式感、不改任何业务流程):
/// 自主模式开启的**瞬间**——整屏覆一层暗幕(界面"融化")→ 大量青色离子从屏幕各处汇聚到**右上角**、
/// 凝成灵枢本体(光球)→ 暗幕退去。之后由常驻悬浮光球 `LingShuFloatingOrb` 接管右上角。
/// 触发:`isStandingPersonOnDuty` 由 false→true(上岗瞬间)。纯表现,`allowsHitTesting(false)` 不挡操作。
struct LingShuAutonomousIntroOverlay: View {
    @ObservedObject var state: LingShuState
    @State private var startedAt: Date?
    private let duration: Double = 2.8

    var body: some View {
        GeometryReader { geo in
            Group {
                if let startedAt {
                    TimelineView(.animation) { tl in
                        let p = min(max(tl.date.timeIntervalSince(startedAt) / duration, 0), 1)
                        AutonomousIntroCanvas(progress: p, size: geo.size)
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onChange(of: state.isStandingPersonOnDuty) { _, onDuty in
                guard onDuty else { startedAt = nil; return }
                startedAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) {
                    if Date().timeIntervalSince(startedAt ?? Date()) >= duration { startedAt = nil }
                }
            }
        }
    }
}

/// 常驻悬浮光球:自主模式在岗时,灵枢本体悬浮在屏幕**右上角**(仪式结束后接管此位)。
/// 轻微上下浮动 = "悬浮"感;复用现成 mini 光球(听/说/思考/执行真实态驱动)。点它=停止并夺回的快捷不做,只展示。
struct LingShuFloatingOrb: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        if state.isStandingPersonOnDuty {
            let snapshot = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: perceptionGateway)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let bob = sin(tl.date.timeIntervalSinceReferenceDate * 1.4) * 4   // 悬浮微浮动
                LingShuDigitalHumanMiniOrb(snapshot: snapshot, audioLevel: Double(voice.outputLevel))
                    .frame(width: 60, height: 60)
                    .shadow(color: Color.lingHolo.opacity(0.5), radius: 14)
                    .offset(y: bob)
            }
            .padding(.top, 56)      // 落在顶栏下方的右上角,不压住导航
            .padding(.trailing, 20)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: state.isStandingPersonOnDuty)
            .help("灵枢自主运行中 · 悬浮本体")
        }
    }
}

/// 仪式的离子粒子场 + 暗幕 + 本体凝聚 + 冲击波(Canvas 一次画完;helper 拆小避免 SwiftUI 类型检查超时)。
private struct AutonomousIntroCanvas: View {
    let progress: Double
    let size: CGSize
    private let particleCount = 120
    private let accent = Color.lingHolo

    var body: some View {
        Canvas { ctx, sz in
            let target = CGPoint(x: sz.width - 64, y: 64)   // 右上角本体落点
            // ① 暗幕(界面"融化"成暗)先铺底,② 之后所有发光元素画在它上面。
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(.black.opacity(veilOpacity(progress))))
            drawCornerGlow(ctx, sz, target: target)
            drawParticles(ctx, sz, target: target)
            drawOrb(ctx, target: target)
            drawShockwave(ctx, target: target)
        }
    }

    // MARK: - 各层

    private func drawCornerGlow(_ ctx: GraphicsContext, _ sz: CGSize, target: CGPoint) {
        // 角落渐起的青色辉光(离子汇聚处越来越亮)。
        let glow = min(max((progress - 0.2) / 0.6, 0), 1)
        guard glow > 0 else { return }
        let r = max(sz.width, sz.height) * (0.25 + 0.35 * glow)
        let grad = Gradient(stops: [
            .init(color: accent.opacity(0.22 * glow), location: 0),
            .init(color: accent.opacity(0.05 * glow), location: 0.5),
            .init(color: .clear, location: 1)
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(grad, center: target, startRadius: 0, endRadius: r)
        )
    }

    private func drawParticles(_ ctx: GraphicsContext, _ sz: CGSize, target: CGPoint) {
        for i in 0..<particleCount {
            let fi = Double(i)
            let sx = Self.hash(fi * 1.13) * Double(sz.width)
            let sy = Self.hash(fi * 2.71 + 5) * Double(sz.height)
            let delay = Self.hash(fi * 3.30) * 0.30
            let psize = 1.4 + Self.hash(fi * 0.70) * 3.2
            let swirl = (Self.hash(fi * 4.10) - 0.5) * 2.4

            let lp = Self.easeInOut(min(max((progress - delay) / (1 - delay), 0), 1))
            // 位置:起点→落点,带逐渐收敛的横向涡流。
            let curve = sin(lp * .pi) * swirl * 60 * (1 - lp)
            let x = sx + (target.x - sx) * lp + curve
            let y = sy + (target.y - sy) * lp - curve * 0.6
            // 透明度:先现身,接近落点更亮,落点后被"吸收"消失。
            let fadeIn = min(lp / 0.15, 1)
            let absorbed = max(0, (lp - 0.92) / 0.08)
            let alpha = fadeIn * (0.35 + 0.65 * lp) * (1 - absorbed)
            guard alpha > 0.01 else { continue }
            let s = psize * (1.0 + 0.6 * lp)
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                with: .color((lp > 0.6 ? Color.white : accent).opacity(alpha))
            )
        }
    }

    private func drawOrb(_ ctx: GraphicsContext, target: CGPoint) {
        let form = min(max((progress - 0.55) / 0.45, 0), 1)   // 凝聚度
        guard form > 0 else { return }
        let r = 30.0 * Self.easeOut(form)
        // 外辉光
        let glowGrad = Gradient(stops: [
            .init(color: accent.opacity(0.55 * form), location: 0),
            .init(color: accent.opacity(0.12 * form), location: 0.55),
            .init(color: .clear, location: 1)
        ])
        let gr = r * 2.4
        ctx.fill(
            Path(ellipseIn: CGRect(x: target.x - gr, y: target.y - gr, width: gr * 2, height: gr * 2)),
            with: .radialGradient(glowGrad, center: target, startRadius: 0, endRadius: gr)
        )
        // 本体核
        let coreGrad = Gradient(stops: [
            .init(color: .white.opacity(0.95 * form), location: 0),
            .init(color: accent.opacity(0.7 * form), location: 0.4),
            .init(color: .clear, location: 1)
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(coreGrad, center: target, startRadius: 0, endRadius: r)
        )
        // 凝成瞬间的白色绽放(~0.9 峰值)
        let bloom = max(0, 1 - abs(progress - 0.9) / 0.1)
        if bloom > 0 {
            let br = r * (1.0 + 1.2 * bloom)
            ctx.fill(
                Path(ellipseIn: CGRect(x: target.x - br, y: target.y - br, width: br * 2, height: br * 2)),
                with: .color(.white.opacity(0.5 * bloom))
            )
        }
    }

    private func drawShockwave(_ ctx: GraphicsContext, target: CGPoint) {
        let w = min(max((progress - 0.82) / 0.18, 0), 1)
        guard w > 0, w < 1 else { return }
        let r = 24 + w * 220
        ctx.stroke(
            Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
            with: .color(accent.opacity(0.5 * (1 - w))),
            lineWidth: 2.5 * (1 - w)
        )
    }

    // MARK: - 工具(纯函数)

    /// 暗幕不透明度:快速融化到 0.58,凝聚完成后退去。
    private func veilOpacity(_ p: Double) -> Double {
        if p < 0.28 { return 0.58 * (p / 0.28) }
        if p < 0.78 { return 0.58 }
        return 0.58 * (1 - (p - 0.78) / 0.22)
    }

    private static func hash(_ n: Double) -> Double {
        let x = sin(n * 12.9898 + 1.7) * 43758.5453
        return x - floor(x)
    }
    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}
