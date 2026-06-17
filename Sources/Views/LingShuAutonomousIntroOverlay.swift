import SwiftUI
import AppKit

/// 自主运行「进入仪式」(用户定调 2026-06-17,只增强仪式感、不改任何业务流程):
/// 自主模式开启的**瞬间**——整屏覆一层暗幕(界面"融化")→ 大量青色离子从屏幕各处汇聚到**右上角**、
/// 凝成灵枢本体(光球)→ 暗幕退去。之后界面整个让位给 `LingShuAutonomousOrbOnlyView`(只剩右上角半透明本体)。
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

/// 自主模式「只剩本体」终态(用户定调 2026-06-17):仪式结束后整窗收缩成一颗**半透明悬浮本体**——
/// 灵枢界面整个消失、化身为右上角的光球,除本体外别无一物。**右键本体**=暂停/继续 + 解除自主模式。
/// 本视图只画本体;窗口收缩成小浮窗 + 透明背景由 `LingShuAutonomousWindowController` 负责。
struct LingShuAutonomousOrbOnlyView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        let snapshot = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: perceptionGateway)
        ZStack {
            Color.clear   // 透明:除本体外什么都没有(窗口背景已设为透明)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let bob = sin(tl.date.timeIntervalSinceReferenceDate * 1.4) * 3   // 悬浮微浮动
                LingShuDigitalHumanMiniOrb(snapshot: snapshot, audioLevel: Double(voice.outputLevel))
                    .frame(width: 92, height: 92)
                    .opacity(0.9)   // 半透明本体
                    .shadow(color: Color.lingHolo.opacity(0.65), radius: 20)
                    .offset(y: bob)
            }
            .contextMenu {   // 右键本体:暂停/继续 + 解除自主模式
                if state.autonomousRun.phase == .paused {
                    Button { state.resumeAutonomousRun() } label: { Label("继续运行", systemImage: "play.fill") }
                } else {
                    Button { state.pauseAutonomousRun() } label: { Label("暂停", systemImage: "pause.fill") }
                }
                Divider()
                Button(role: .destructive) { state.stopAutonomousRun() } label: { Label("解除自主模式", systemImage: "hand.raised.fill") }
            }
            .help("灵枢自主运行中 · 右键：暂停/继续、解除自主模式")
        }
        .frame(width: 104, height: 104)
        .transition(.scale(scale: 0.3).combined(with: .opacity))
    }
}

/// 自主模式终态的窗口处理:把灵枢主窗口**收缩成右上角的小浮窗 + 透明背景 + 隐藏标题栏/红绿灯**,
/// 让"界面消失、只剩本体"成立(本体是圆的,透明背景=圆球悬浮)。退出自主模式时**完整还原**窗口
/// (尺寸/不透明/标题栏/红绿灯/层级)。务实:有右键「解除自主模式」兜底,任何时候都能回到正常界面。
struct LingShuAutonomousWindowController: NSViewRepresentable {
    let active: Bool   // true = 进入只剩本体的小浮窗终态

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if active, !coord.shrunk {
                coord.capture(window)
                applyOrbMode(window)
                coord.shrunk = true
            } else if !active, coord.shrunk {
                coord.restore(window)
                coord.shrunk = false
            }
        }
    }

    private func applyOrbMode(_ w: NSWindow) {
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true }
        w.minSize = NSSize(width: 80, height: 80)
        w.level = .floating
        if let screen = w.screen ?? NSScreen.main {
            let s: CGFloat = 116, margin: CGFloat = 26
            let vf = screen.visibleFrame
            w.setFrame(NSRect(x: vf.maxX - s - margin, y: vf.maxY - s - margin, width: s, height: s), display: true, animate: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shrunk = false
        private var frame: NSRect?
        private var opaque = true
        private var bg: NSColor?
        private var shadow = true
        private var titlebarTransparent = false
        private var titleVis: NSWindow.TitleVisibility = .visible
        private var level: NSWindow.Level = .normal
        private var minSize = NSSize.zero
        private var hiddenButtons: [NSWindow.ButtonType: Bool] = [:]

        func capture(_ w: NSWindow) {
            frame = w.frame; opaque = w.isOpaque; bg = w.backgroundColor; shadow = w.hasShadow
            titlebarTransparent = w.titlebarAppearsTransparent; titleVis = w.titleVisibility
            level = w.level; minSize = w.minSize
            [.closeButton, .miniaturizeButton, .zoomButton].forEach { hiddenButtons[$0] = w.standardWindowButton($0)?.isHidden ?? false }
        }

        func restore(_ w: NSWindow) {
            w.isOpaque = opaque; w.backgroundColor = bg; w.hasShadow = shadow
            w.titlebarAppearsTransparent = titlebarTransparent; w.titleVisibility = titleVis
            w.level = level; w.minSize = minSize
            hiddenButtons.forEach { w.standardWindowButton($0.key)?.isHidden = $0.value }
            if let frame { w.setFrame(frame, display: true, animate: true) }
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
