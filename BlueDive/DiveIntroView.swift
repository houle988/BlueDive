import SwiftUI
#if os(iOS)
import UIKit
import CoreMotion
#endif

private final class TiltMotion {
    private(set) var roll: Double = 0
    private(set) var pitch: Double = 0
    #if os(iOS)
    private let manager = CMMotionManager()
    private var baseRoll = 0.0
    private var basePitch = 0.0
    private var hasBase = false
    #endif

    func start() {
        #if os(iOS)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            if !self.hasBase {
                self.baseRoll = m.attitude.roll
                self.basePitch = m.attitude.pitch
                self.hasBase = true
            }
            let targetRoll = max(-0.8, min(0.8, m.attitude.roll - self.baseRoll))
            let targetPitch = max(-0.8, min(0.8, m.attitude.pitch - self.basePitch))
            self.roll += (targetRoll - self.roll) * 0.1
            self.pitch += (targetPitch - self.pitch) * 0.1
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        manager.stopDeviceMotionUpdates()
        #endif
    }
}

private enum IntroTiming {
    static let total: Double = 6.3
    static let lock: Double = 2.6
    static let ascent: Double = 5.4
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

private func easeOutBack(_ t: Double) -> Double {
    let c1 = 1.70158
    let c3 = c1 + 1
    let u = t - 1
    return 1 + c3 * u * u * u + c1 * u * u
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

private func fract(_ x: Double) -> Double { x - floor(x) }

private func unitRandom(_ seed: Int, _ salt: Int) -> Double {
    var h = UInt64(bitPattern: Int64(seed &+ 1)) &* 0x9E3779B97F4A7C15
    h ^= UInt64(bitPattern: Int64(salt &+ 1)) &* 0xBF58476D1CE4E5B9
    h ^= h >> 31
    h = h &* 0x94D049BB133111EB
    h ^= h >> 29
    return Double(h % 1_000_000) / 1_000_000
}

private func mixColour(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
    Color(red: lerp(a.0, b.0, t), green: lerp(a.1, b.1, t), blue: lerp(a.2, b.2, t))
}

private func squirclePoint(_ theta: Double, half: Double) -> CGPoint {
    let c = cos(theta)
    let s = sin(theta)
    let x = half * (c < 0 ? -1.0 : 1.0) * pow(abs(c), 0.55)
    let y = half * (s < 0 ? -1.0 : 1.0) * pow(abs(s), 0.55)
    return CGPoint(x: x, y: y)
}

private func introSurfaceMix(_ e: Double) -> Double {
    clamp01((1 - smoothstep(0.0, 1.0, e)) + smoothstep(IntroTiming.ascent, 6.2, e))
}

private func shockFront(_ e: Double, wave: Int) -> (progress: Double, fade: Double)? {
    let t0 = IntroTiming.lock + Double(wave) * 0.24
    let raw = (e - t0) / 0.9
    guard raw > 0, raw < 1 else { return nil }
    return (1 - pow(1 - raw, 2.3), 1 - raw)
}

private func bubbleWarp(_ t: Double) -> Double {
    t + 1.6 * (1 - exp(-t * 2.2)) + 2.8 * pow(max(0, t - IntroTiming.ascent), 2)
}

private func bubbleWarpRate(_ t: Double) -> Double {
    1 + 3.52 * exp(-t * 2.2) + 5.6 * max(0, t - IntroTiming.ascent)
}

struct DiveIntroView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finished = false
    @State private var start = Date()
    @State private var tilt = TiltMotion()
    @State private var reducedAppear = false

    var body: some View {
        ZStack {
            if reduceMotion {
                reducedIntro
            } else {
                fullIntro
            }
        }
        .background(Color.black)
        .task(id: reduceMotion) {
            let duration = reduceMotion ? 1.6 : IntroTiming.total
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            finishOnce()
        }
    }

    private var fullIntro: some View {
        GeometryReader { proxy in
            let unit = min(proxy.size.width, proxy.size.height)
            TimelineView(.animation) { timeline in
                let e = timeline.date.timeIntervalSince(start)
                let surge = e > IntroTiming.lock ? 1 + 0.02 * exp(-(e - IntroTiming.lock) * 4.5) : 1
                let tx = tilt.roll
                let ty = tilt.pitch
                ZStack {
                    backdrop(e: e)
                        .scaleEffect(1.14)
                        .offset(x: tx * unit * 0.02, y: ty * unit * 0.015)
                    FarOceanCanvas(e: e)
                        .scaleEffect(1.1)
                        .offset(x: tx * unit * 0.038, y: ty * unit * 0.03)
                    NearOceanCanvas(e: e)
                        .scaleEffect(1.06)
                        .offset(x: tx * unit * 0.062, y: ty * unit * 0.05)
                    heroLayer(e: e, size: proxy.size)
                        .offset(x: tx * unit * 0.04, y: ty * unit * 0.032)
                        .rotation3DEffect(.degrees(tx * 6), axis: (x: 0, y: 1, z: 0))
                        .rotation3DEffect(.degrees(-ty * 5), axis: (x: 1, y: 0, z: 0))
                    bloomOverlay(e: e)
                }
                .scaleEffect(surge)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
                .overlay(alignment: .topTrailing) {
                    skipButton(e: e)
                        .padding(.top, 60)
                        .padding(.trailing, 20)
                }
            }
        }
        .onAppear { tilt.start() }
        .onDisappear { tilt.stop() }
        .task {
            #if os(iOS)
            let impact = UIImpactFeedbackGenerator(style: .soft)
            impact.prepare()
            #endif
            try? await Task.sleep(for: .seconds(IntroTiming.lock))
            guard !Task.isCancelled, !finished else { return }
            #if os(iOS)
            impact.impactOccurred()
            #endif
        }
    }

    private var reducedIntro: some View {
        GeometryReader { proxy in
            let base = min(proxy.size.width, proxy.size.height)
            let iconSize = base * 0.32
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.16, blue: 0.3),
                        Color(red: 0.02, green: 0.08, blue: 0.18),
                        Color(red: 0.0, green: 0.03, blue: 0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                VStack(spacing: iconSize * 0.22) {
                    staticIcon(iconSize: iconSize)
                        .opacity(reducedAppear ? 1 : 0)
                        .scaleEffect(reducedAppear ? 1 : 0.94)
                    VStack(spacing: 10) {
                        Text(verbatim: "BlueDive")
                            .font(.system(size: min(base * 0.09, 52), weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: Color(red: 0.2, green: 0.8, blue: 1.0).opacity(0.7), radius: 14)
                        Text("Every dive, relived perfectly.")
                            .font(.system(size: min(base * 0.034, 17), weight: .medium, design: .rounded))
                            .tracking(3)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .opacity(reducedAppear ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                skipButton(e: 1.0)
                    .padding(.top, 60)
                    .padding(.trailing, 20)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { reducedAppear = true }
        }
    }

    private func staticIcon(iconSize: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
        return Image("BlueDiveIcon")
            .resizable()
            .scaledToFill()
            .frame(width: iconSize, height: iconSize)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.7), Color.white.opacity(0.1), Color.white.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Color(red: 0.15, green: 0.7, blue: 1.0).opacity(0.5), radius: 22)
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    private func skipButton(e: Double) -> some View {
        Button {
            finishOnce()
        } label: {
            HStack(spacing: 6) {
                Text("Skip")
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(smoothstep(0.4, 0.9, e))
        .allowsHitTesting(e > 0.4)
        .zIndex(1000)
    }

    @ViewBuilder
    private func backdrop(e: Double) -> some View {
        let s = introSurfaceMix(e)
        if #available(iOS 18.0, macOS 15.0, *) {
            MeshGradient(width: 3, height: 3, points: meshPoints(e: e), colors: meshColors(e: e, surface: s))
        } else {
            LinearGradient(
                colors: [
                    mixColour((0.012, 0.09, 0.21), (0.5, 0.88, 1.0), s),
                    mixColour((0.004, 0.05, 0.15), (0.16, 0.56, 0.86), s),
                    mixColour((0.0, 0.02, 0.08), (0.05, 0.35, 0.6), s)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func meshPoints(e: Double) -> [SIMD2<Float>] {
        [
            SIMD2(0, 0),
            SIMD2(Float(0.5 + 0.06 * sin(e * 0.42)), 0),
            SIMD2(1, 0),
            SIMD2(0, Float(0.5 + 0.05 * cos(e * 0.36 + 1.1))),
            SIMD2(Float(0.5 + 0.09 * sin(e * 0.6)), Float(0.5 + 0.09 * cos(e * 0.5 + 1.3))),
            SIMD2(1, Float(0.5 + 0.05 * sin(e * 0.31 + 2.2))),
            SIMD2(0, 1),
            SIMD2(Float(0.5 + 0.06 * cos(e * 0.47 + 0.7)), 1),
            SIMD2(1, 1)
        ]
    }

    private func meshColors(e: Double, surface: Double) -> [Color] {
        let sh = 0.014 * sin(e * 0.8)
        let sh2 = 0.012 * cos(e * 0.63 + 1.4)
        return [
            mixColour((0.012, 0.095 + sh, 0.215), (0.55, 0.9, 1.0), surface),
            mixColour((0.02, 0.125 + sh2, 0.26), (0.66, 0.94, 1.0), surface),
            mixColour((0.01, 0.085 - sh, 0.205), (0.52, 0.89, 1.0), surface),
            mixColour((0.005, 0.055 + sh2, 0.16), (0.2, 0.6, 0.9), surface),
            mixColour((0.012, 0.085 + sh, 0.2), (0.3, 0.72, 0.97), surface),
            mixColour((0.004, 0.05 - sh2, 0.15), (0.18, 0.58, 0.88), surface),
            mixColour((0.0, 0.02, 0.08), (0.06, 0.38, 0.64), surface),
            mixColour((0.002, 0.03 + sh, 0.1), (0.09, 0.44, 0.7), surface),
            mixColour((0.0, 0.018, 0.075), (0.05, 0.35, 0.6), surface)
        ]
    }

    @ViewBuilder
    private func heroLayer(e: Double, size: CGSize) -> some View {
        let base = min(size.width, size.height)
        let iconSize = base * 0.32
        let cornerRadius = iconSize * 0.22
        let appear = smoothstep(1.9, 2.7, e)
        let overshoot = easeOutBack(appear)
        let breathe = 1 + 0.008 * sin(e * 2.3)
        let scale = (0.4 + 0.6 * overshoot) * breathe
        let damp = 1 - smoothstep(IntroTiming.ascent, 6.0, e)
        let entrance = (1 - appear) * 28 * damp
        let orbitY = sin(e * 0.85) * 16 * appear * damp
        let nodX = sin(e * 0.63 + 1.0) * 6.5 * appear * damp
        let flash = e > IntroTiming.lock ? exp(-(e - IntroTiming.lock) * 3.4) : 0
        let bob = sin(e * 1.4) * 3 * appear * damp
        let heroDrop = smoothstep(IntroTiming.ascent + 0.05, IntroTiming.total, e)

        VStack(spacing: iconSize * 0.22) {
            ZStack {
                shockwaveRings(e: e, iconSize: iconSize)
                godBurst(e: e, iconSize: iconSize)
                sonarRings(e: e, iconSize: iconSize)
                lockFlash(flash: flash, iconSize: iconSize)
                anamorphicFlare(flash: flash, iconSize: iconSize)

                iconView(e: e, iconSize: iconSize, cornerRadius: cornerRadius)
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.02, green: 0.16, blue: 0.32),
                                        Color(red: 0.0, green: 0.05, blue: 0.14)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: iconSize, height: iconSize)
                            .offset(x: iconSize * 0.045, y: iconSize * 0.03)
                            .blur(radius: 0.5)
                    }
                    .scaleEffect(scale)
                    .rotation3DEffect(
                        .degrees(entrance + orbitY),
                        axis: (x: 0.0, y: 1.0, z: 0.0),
                        perspective: 0.85
                    )
                    .rotation3DEffect(
                        .degrees(nodX),
                        axis: (x: 1.0, y: 0.0, z: 0.0),
                        perspective: 0.85
                    )
                    .opacity(appear)
                    .blur(radius: (1 - appear) * 12)
                    .saturation(0.55 + 0.45 * appear)
                    .offset(y: bob)
            }
            .frame(width: iconSize, height: iconSize)

            wordmark(e: e, base: base)
        }
        .offset(y: heroDrop * size.height * 0.42)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func godBurst(e: Double, iconSize: CGFloat) -> some View {
        let ignite = smoothstep(IntroTiming.lock - 0.18, IntroTiming.lock + 0.28, e)
        let sustain = ignite * (1 - smoothstep(IntroTiming.ascent - 0.1, 6.0, e))
        let flash = e > IntroTiming.lock ? exp(-(e - IntroTiming.lock) * 2.5) : 0
        let amp = clamp01(sustain * 0.55 + flash)
        return ZStack {
            ForEach(0..<14, id: \.self) { k in
                let long = k % 2 == 0
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color(red: 0.72, green: 0.96, blue: 1.0).opacity(long ? 0.55 : 0.32),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: iconSize * (long ? 0.11 : 0.06), height: iconSize * (long ? 3.4 : 2.4))
                    .rotationEffect(.degrees(Double(k) / 14 * 360))
            }
        }
        .blur(radius: 2.2)
        .rotationEffect(.degrees(e * 10))
        .scaleEffect(0.86 + 0.28 * flash)
        .opacity(amp * 0.9)
        .blendMode(.screen)
    }

    private func lockFlash(flash: Double, iconSize: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.55),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: iconSize * 1.4
                )
            )
            .frame(width: iconSize * 2.8, height: iconSize * 2.8)
            .opacity(flash * 0.95)
            .blendMode(.screen)
    }

    @ViewBuilder
    private func shockwaveRings(e: Double, iconSize: CGFloat) -> some View {
        ForEach(0..<2, id: \.self) { index in
            let t0 = IntroTiming.lock + Double(index) * 0.22
            let raw = (e - t0) / 0.95
            if raw > 0, raw < 1 {
                let p = 1 - pow(1 - raw, 2.4)
                let fade = 1 - raw
                ZStack {
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.92, blue: 1.0).opacity(0.55),
                                    Color.white.opacity(0.85),
                                    Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.45),
                                    Color.white.opacity(0.85),
                                    Color(red: 0.55, green: 0.92, blue: 1.0).opacity(0.55)
                                ],
                                center: .center
                            ),
                            lineWidth: 16 * fade + 2
                        )
                        .blur(radius: 5 * fade)
                    Circle()
                        .strokeBorder(Color.white.opacity(fade * 0.8), lineWidth: 1.4)
                    Circle()
                        .strokeBorder(Color(red: 0.0, green: 0.12, blue: 0.25).opacity(fade * 0.4), lineWidth: 9 * fade + 1)
                        .scaleEffect(0.92)
                        .blur(radius: 3)
                }
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(1 + p * 7.5)
                .opacity(Double(fade))
                .blendMode(.screen)
            }
        }
    }

    @ViewBuilder
    private func sonarRings(e: Double, iconSize: CGFloat) -> some View {
        ForEach(0..<5, id: \.self) { index in
            let ringStart = IntroTiming.lock + Double(index) * 0.16
            let p = clamp01((e - ringStart) / 1.1)
            if p > 0, p < 1 {
                Circle()
                    .strokeBorder(
                        Color(red: 0.45, green: 0.9, blue: 1.0).opacity((1 - p) * (0.62 - Double(index) * 0.07)),
                        lineWidth: 2.4 * (1 - p) + 0.5
                    )
                    .frame(width: iconSize, height: iconSize)
                    .scaleEffect(1 + p * (2.2 + Double(index) * 0.55))
            }
        }
    }

    private func anamorphicFlare(flash: Double, iconSize: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color(red: 1.0, green: 0.4, blue: 0.72).opacity(0.55), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: iconSize * (3.8 + flash * 1.2), height: 3)
                .offset(y: 2.4)
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color(red: 0.35, green: 0.85, blue: 1.0).opacity(0.7), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: iconSize * (3.8 + flash * 1.2), height: 3)
                .offset(y: -2.4)
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.92), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: iconSize * (3.3 + flash * 2.0), height: 2.2)
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2, height: iconSize * (1.9 + flash))
            ForEach(0..<2, id: \.self) { spike in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.4), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: iconSize * 2.2, height: 1)
                    .rotationEffect(.degrees(spike == 0 ? 45 : -45))
            }
        }
        .opacity(flash * 0.95)
        .blendMode(.screen)
    }

    private func iconView(e: Double, iconSize: CGFloat, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glare = smoothstep(IntroTiming.lock, IntroTiming.lock + 0.85, e)
        let glare2 = smoothstep(IntroTiming.lock + 0.55, IntroTiming.lock + 1.5, e)
        let split = e > IntroTiming.lock ? exp(-(e - IntroTiming.lock) * 5.2) : 0
        let splitOffset = CGFloat(split) * iconSize * 0.05

        return ZStack {
            Image("BlueDiveIcon")
                .resizable()
                .scaledToFill()
                .frame(width: iconSize, height: iconSize)
            Image("BlueDiveIcon")
                .resizable()
                .scaledToFill()
                .frame(width: iconSize, height: iconSize)
                .colorMultiply(Color(red: 1.0, green: 0.2, blue: 0.25))
                .offset(x: -splitOffset, y: splitOffset * 0.3)
                .opacity(split * 0.8)
                .blendMode(.screen)
            Image("BlueDiveIcon")
                .resizable()
                .scaledToFill()
                .frame(width: iconSize, height: iconSize)
                .colorMultiply(Color(red: 0.2, green: 0.55, blue: 1.0))
                .offset(x: splitOffset, y: -splitOffset * 0.3)
                .opacity(split * 0.8)
                .blendMode(.screen)
            iconFaceCaustics(e: e, iconSize: iconSize)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), .clear, Color.black.opacity(0.16)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.5), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: iconSize * 0.16
                    )
                )
                .frame(width: iconSize * 0.32, height: iconSize * 0.32)
                .offset(x: -iconSize * 0.3, y: -iconSize * 0.32)
                .blendMode(.screen)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.65), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: iconSize * 0.45, height: iconSize * 1.8)
                .rotationEffect(.degrees(24))
                .offset(
                    x: -iconSize + glare * iconSize * 2,
                    y: (glare - 0.5) * iconSize * 0.4
                )
                .opacity(0.9)
                .blendMode(.screen)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color(red: 0.75, green: 0.96, blue: 1.0).opacity(0.5), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: iconSize * 0.2, height: iconSize * 1.8)
                .rotationEffect(.degrees(-20))
                .offset(
                    x: iconSize - glare2 * iconSize * 2,
                    y: (0.5 - glare2) * iconSize * 0.3
                )
                .opacity(0.7)
                .blendMode(.screen)
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.75),
                        Color.white.opacity(0.08),
                        Color.white.opacity(0.38)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .overlay {
            shape
                .inset(by: 1.5)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                .blur(radius: 1.4)
        }
        .shadow(color: Color(red: 0.15, green: 0.7, blue: 1.0).opacity(0.6), radius: 26)
        .shadow(color: Color.white.opacity(split * 0.5), radius: 12)
    }

    private func iconFaceCaustics(e: Double, iconSize: CGFloat) -> some View {
        let flashBoost = e > IntroTiming.lock ? exp(-(e - IntroTiming.lock) * 2.2) : 0
        let intensity = 0.24 + 0.5 * flashBoost
        return ZStack {
            ForEach(0..<3, id: \.self) { k in
                let fk = Double(k)
                let ox = sin(e * (0.9 + fk * 0.37) + fk * 2.1) * iconSize * 0.28
                let oy = cos(e * (0.7 + fk * 0.29) + fk * 1.4) * iconSize * 0.26
                let pulse = 0.55 + 0.45 * sin(e * (1.6 + fk) + fk * 2.6)
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.75, green: 0.97, blue: 1.0).opacity(0.5 * pulse),
                                Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.16 * pulse),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: iconSize * 0.42
                        )
                    )
                    .frame(width: iconSize * 0.9, height: iconSize * 0.7)
                    .offset(x: ox, y: oy)
            }
        }
        .blendMode(.plusLighter)
        .opacity(intensity)
    }

    private func wordmark(e: Double, base: CGFloat) -> some View {
        let titleIn = smoothstep(2.95, 3.55, e)
        let tagIn = smoothstep(3.25, 3.9, e)
        let damp = 1 - smoothstep(IntroTiming.ascent, 5.9, e)
        let bob = sin(e * 1.1 + 0.7) * 2.5 * titleIn * damp
        let sweep = clamp01((e - 3.3) / 0.95)
        let sweep2 = clamp01((e - 3.85) / 0.8)
        let titleFont = Font.system(size: min(base * 0.09, 52), weight: .bold, design: .rounded)

        return VStack(spacing: 10) {
            Text(verbatim: "BlueDive")
                .font(titleFont)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, Color(red: 0.78, green: 0.95, blue: 1.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay { titleSweep(sweep, base: base, font: titleFont, strength: 1.0) }
                .overlay { titleSweep(sweep2, base: base, font: titleFont, strength: 0.55) }
                .shadow(color: Color(red: 0.2, green: 0.8, blue: 1.0).opacity(0.85), radius: 16)
                .opacity(titleIn)
                .blur(radius: (1 - titleIn) * 6)
                .offset(y: (1 - easeOutBack(titleIn)) * 34 + bob)
                .scaleEffect(0.92 + 0.08 * easeOutBack(titleIn))

            Text("Every dive, relived perfectly.")
                .font(.system(size: min(base * 0.034, 17), weight: .medium, design: .rounded))
                .tracking(lerp(9, 3, tagIn))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: Color(red: 0.2, green: 0.7, blue: 1.0).opacity(0.5), radius: 8)
                .opacity(tagIn)
                .blur(radius: (1 - tagIn) * 3)
                .offset(y: (1 - tagIn) * 16 + bob * 0.6)
        }
    }

    private func titleSweep(_ sweep: Double, base: CGFloat, font: Font, strength: Double) -> some View {
        LinearGradient(
            colors: [
                .clear,
                Color(red: 0.7, green: 0.96, blue: 1.0).opacity(0.95),
                Color.white,
                Color(red: 0.7, green: 0.96, blue: 1.0).opacity(0.95),
                .clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .scaleEffect(x: 0.35)
        .offset(x: (sweep * 2.4 - 1.2) * base * 0.42)
        .blendMode(.screen)
        .opacity(sweep > 0.001 && sweep < 0.999 ? strength : 0)
        .mask(Text(verbatim: "BlueDive").font(font))
    }

    private func bloomOverlay(e: Double) -> some View {
        let bloom = smoothstep(5.58, 6.22, e)
        let lockFlash = e > IntroTiming.lock ? exp(-(e - IntroTiming.lock) * 5.5) : 0
        return RadialGradient(
            colors: [
                Color.white,
                Color(red: 0.6, green: 0.93, blue: 1.0).opacity(0.95),
                Color(red: 0.25, green: 0.7, blue: 0.95).opacity(0.85)
            ],
            center: UnitPoint(x: 0.5, y: 0.35),
            startRadius: 0,
            endRadius: 900
        )
        .opacity(bloom + lockFlash * 0.18)
        .allowsHitTesting(false)
    }
}

private struct FarOceanCanvas: View {
    let e: Double

    // Precomputed per-particle random values — frame-invariant constants computed once
    // via Swift's lazy atomic `static let`, then read-only (safe for async canvas).
    private static let _b221:     [Double] = (0..<8).map  { unitRandom($0, 221) }
    private static let _b222:     [Double] = (0..<8).map  { unitRandom($0, 222) }
    private static let _b223:     [Double] = (0..<8).map  { unitRandom($0, 223) }
    private static let _cf11:     [Double] = (0..<35).map { unitRandom($0, 11)  }
    private static let _cf12:     [Double] = (0..<35).map { unitRandom($0, 12)  }
    private static let _cs15:     [Double] = (0..<6).map  { unitRandom($0, 15)  }
    private static let _cs16:     [Double] = (0..<6).map  { unitRandom($0, 16)  }
    private static let _gr52:     [Double] = (0..<10).map { unitRandom($0, 52)  }
    private static let _fs301:    [Double] = (0..<16).map { unitRandom($0, 301) }
    private static let _fs302:    [Double] = (0..<16).map { unitRandom($0, 302) }
    private static let _fs303:    [Double] = (0..<16).map { unitRandom($0, 303) }
    private static let _fs304:    [Double] = (0..<16).map { unitRandom($0, 304) }
    private static let _kp321:    [Double] = (0..<8).map  { unitRandom($0, 321) }
    private static let _kp322:    [Double] = (0..<8).map  { unitRandom($0, 322) }
    private static let _kp323:    [Double] = (0..<8).map  { unitRandom($0, 323) }
    private static let _fd55:     [Double] = (0..<30).map { unitRandom($0, 55)  }
    private static let _fd56:     [Double] = (0..<30).map { unitRandom($0, 56)  }
    private static let _fd57:     [Double] = (0..<30).map { unitRandom($0, 57)  }
    private static let _fsnow161: [Double] = (0..<24).map { unitRandom($0, 161) }
    private static let _fsnow162: [Double] = (0..<24).map { unitRandom($0, 162) }
    private static let _fsnow163: [Double] = (0..<24).map { unitRandom($0, 163) }
    private static let _fb171:    [Double] = (0..<16).map { unitRandom($0, 171) }
    private static let _fb172:    [Double] = (0..<16).map { unitRandom($0, 172) }
    private static let _fb173:    [Double] = (0..<16).map { unitRandom($0, 173) }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            drawDepthShade(&context, size: size)
            drawDeepGlow(&context, size: size)
            drawBokeh(&context, size: size)
            drawCausticField(&context, size: size)
            drawGodRayFan(&context, size: size)
            drawKelp(&context, size: size)
            drawMantaGlide(&context, size: size)
            drawJellyfish(&context, size: size)
            drawFishSchool(&context, size: size)
            drawFarDust(&context, size: size)
            drawFarSnow(&context, size: size)
            drawFarBubbles(&context, size: size)
            drawThermocline(&context, size: size)
        }
        .blur(radius: 2.4)
        .scaleEffect(1.045)
        .scaleEffect(x: 1 + 0.005 * sin(e * 1.6 + 0.4), y: 1 + 0.005 * cos(e * 1.3))
        .rotationEffect(.degrees(0.22 * sin(e * 0.7)))
        .allowsHitTesting(false)
    }

    private func drawDepthShade(_ context: inout GraphicsContext, size: CGSize) {
        let s = introSurfaceMix(e)
        let deep = 1 - s
        guard deep > 0.01 else { return }
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.02, green: 0.1, blue: 0.22).opacity(0.3 * deep),
                    Color(red: 0.0, green: 0.03, blue: 0.1).opacity(0.5 * deep),
                    Color(red: 0.0, green: 0.01, blue: 0.05).opacity(0.75 * deep)
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    private func drawDeepGlow(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let glow = 0.1 + 0.32 * smoothstep(2.0, 2.7, e) * (1 - smoothstep(5.7, 6.2, e))
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [Color(red: 0.15, green: 0.5, blue: 0.8).opacity(glow), .clear]),
                center: CGPoint(x: w / 2, y: h * 0.46),
                startRadius: 0,
                endRadius: min(w, h) * 0.75
            )
        )
        let abyss = (1 - introSurfaceMix(e)) * 0.5
        guard abyss > 0.02 else { return }
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [Color(red: 0.0, green: 0.005, blue: 0.03).opacity(abyss), .clear]),
                center: CGPoint(x: w / 2, y: h * 1.15),
                startRadius: 0,
                endRadius: h * 0.75
            )
        )
    }

    private func drawBokeh(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let vis = clamp01(0.35 + 0.4 * smoothstep(0.4, 1.2, e)) * (1 - 0.55 * smoothstep(5.7, 6.2, e))
        guard vis > 0.02 else { return }
        let ascentRate = max(0, e - IntroTiming.ascent)
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<8 {
            let r1 = Self._b221[i]
            let r2 = Self._b222[i]
            let r3 = Self._b223[i]
            let prog = fract(r1 + e * 0.01 * (0.3 + 0.5 * r2) + ascentRate * ascentRate * 0.3)
            let x = w * r2 + sin(e * (0.2 + 0.3 * r3) + Double(i) * 1.7) * 34
            let y = h * (1.12 - prog * 1.24)
            let radius = 44 + 82 * r3
            let pulse = 0.6 + 0.4 * sin(e * (0.8 + r1) + Double(i))
            let alpha = vis * (0.05 + 0.06 * r3) * pulse
            guard alpha > 0.006 else { continue }
            let colour = mixColour((0.3, 0.7, 1.0), (0.62, 0.95, 1.0), r1)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [colour.opacity(alpha), colour.opacity(alpha * 0.3), .clear]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: radius
                )
            )
            ctx.stroke(Path(ellipseIn: rect), with: .color(colour.opacity(alpha * 0.55)), lineWidth: 1.2)
        }
    }

    private func drawCausticField(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let intensity = clamp01(0.3 + 0.5 * smoothstep(0.4, 1.1, e) + 0.75 * smoothstep(IntroTiming.ascent, 6.1, e))
        guard intensity > 0.02 else { return }
        var ctx = context
        ctx.blendMode = .plusLighter
        let cols = 7
        let rows = 5
        for row in 0..<rows {
            for col in 0..<cols {
                let i = row * cols + col
                let r1 = Self._cf11[i]
                let r2 = Self._cf12[i]
                let bx = w * (Double(col) + 0.5) / Double(cols)
                let by = h * 0.68 * (Double(row) + 0.5) / Double(rows)
                let x = bx + sin(e * (0.5 + 0.3 * r1) + Double(i) * 1.7) * 26
                let y = by + cos(e * (0.4 + 0.25 * r2) + Double(i) * 2.3) * 18
                let cell = abs(sin(e * 0.9 + r1 * 6.28) * sin(e * 0.63 + r2 * 6.28 + Double(i)))
                let sharp = pow(cell, 3)
                let radius = 24 + 42 * r2
                let alpha = intensity * sharp * 0.11
                guard alpha > 0.004 else { continue }
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 0.6, green: 0.95, blue: 1.0).opacity(alpha),
                            Color(red: 0.35, green: 0.8, blue: 1.0).opacity(alpha * 0.4),
                            .clear
                        ]),
                        center: CGPoint(x: x, y: y),
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }
        for i in 0..<6 {
            let r1 = Self._cs15[i]
            let r2 = Self._cs16[i]
            let x = w * (0.12 + 0.76 * r1) + sin(e * (0.3 + 0.2 * r2) + Double(i) * 2.4) * 40
            let y = h * (0.1 + 0.5 * r2) + cos(e * (0.24 + 0.18 * r1) + Double(i) * 1.6) * 30
            let cell = abs(sin(e * 0.5 + r1 * 6.28) * sin(e * 0.37 + r2 * 6.28 + Double(i) * 1.3))
            let alpha = intensity * pow(cell, 2.4) * 0.07
            guard alpha > 0.004 else { continue }
            let radius = 70 + 90 * r2
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 0.5, green: 0.9, blue: 1.0).opacity(alpha),
                        .clear
                    ]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private func drawGodRayFan(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let swell = smoothstep(IntroTiming.ascent, 6.1, e)
        let intensity = clamp01(0.3 + 0.7 * (1 - smoothstep(0.4, 1.4, e)) + 1.15 * swell)
        guard intensity > 0.02 else { return }
        let pivot = CGPoint(x: w * 0.5, y: -h * 0.42)
        let rot = e * 0.03 + 0.05 * sin(e * 0.45)
        let len = h * 2.1
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<10 {
            let fi = Double(i)
            let a = rot + (fi - 4.5) * 0.15 + 0.05 * sin(e * 0.7 + fi * 2.3)
            let halfW = (0.01 + 0.02 * Self._gr52[i]) * (1 + swell * 0.8)
            let alpha = max(0, intensity * (0.055 + 0.055 * (0.5 + 0.5 * sin(e * 0.85 + fi * 1.9))))
            guard alpha > 0.004 else { continue }
            let l = a - halfW
            let r = a + halfW
            var path = Path()
            path.move(to: pivot)
            path.addLine(to: CGPoint(x: pivot.x + sin(l) * len, y: pivot.y + cos(l) * len))
            path.addLine(to: CGPoint(x: pivot.x + sin(r) * len, y: pivot.y + cos(r) * len))
            path.closeSubpath()
            ctx.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.8, green: 0.97, blue: 1.0).opacity(alpha),
                        Color(red: 0.4, green: 0.8, blue: 1.0).opacity(alpha * 0.45),
                        .clear
                    ]),
                    startPoint: CGPoint(x: pivot.x, y: 0),
                    endPoint: CGPoint(x: pivot.x, y: h * 0.95)
                )
            )
        }
    }

    private func drawMantaGlide(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let cross = smoothstep(0.8, 3.5, e)
        let vis = smoothstep(0.85, 1.5, e) * (1 - smoothstep(3.05, 3.6, e))
        guard vis > 0.02 else { return }
        let cx = -w * 0.28 + cross * (w * 1.56)
        let cy = h * 0.34 + sin(e * 0.6) * h * 0.028
        let span = min(w, h) * 0.46
        let chord = span * 0.62
        let flap = sin(e * 1.7)

        func manta(_ scaleY: Double) -> Path {
            var p = Path()
            let tipY = flap * chord * 0.42 * scaleY
            p.move(to: CGPoint(x: cx - span, y: cy + tipY))
            p.addQuadCurve(to: CGPoint(x: cx, y: cy - chord * 0.55 * scaleY),
                           control: CGPoint(x: cx - span * 0.42, y: cy - chord * 0.95 * scaleY))
            p.addQuadCurve(to: CGPoint(x: cx + span, y: cy + tipY),
                           control: CGPoint(x: cx + span * 0.42, y: cy - chord * 0.95 * scaleY))
            p.addQuadCurve(to: CGPoint(x: cx, y: cy + chord * 0.42 * scaleY),
                           control: CGPoint(x: cx + span * 0.42, y: cy + chord * 0.5 * scaleY))
            p.addQuadCurve(to: CGPoint(x: cx - span, y: cy + tipY),
                           control: CGPoint(x: cx - span * 0.42, y: cy + chord * 0.5 * scaleY))
            p.closeSubpath()
            var tail = Path()
            tail.move(to: CGPoint(x: cx - span * 0.05, y: cy + chord * 0.3 * scaleY))
            tail.addQuadCurve(to: CGPoint(x: cx + span * 0.02, y: cy + chord * 1.35 * scaleY),
                              control: CGPoint(x: cx + span * 0.12, y: cy + chord * 0.8 * scaleY))
            tail.addLine(to: CGPoint(x: cx - span * 0.03, y: cy + chord * 0.34 * scaleY))
            tail.closeSubpath()
            p.addPath(tail)
            let fin = span * 0.11
            p.addPath(Path(ellipseIn: CGRect(x: cx - fin * 1.5, y: cy - chord * 0.62 * scaleY, width: fin, height: fin * 1.7)))
            p.addPath(Path(ellipseIn: CGRect(x: cx + fin * 0.5, y: cy - chord * 0.62 * scaleY, width: fin, height: fin * 1.7)))
            return p
        }

        let body = manta(1.0)
        context.fill(body, with: .color(Color(red: 0.0, green: 0.02, blue: 0.06).opacity(0.55 * vis)))
        context.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.02, green: 0.14, blue: 0.28).opacity(0.4 * vis),
                    Color(red: 0.0, green: 0.02, blue: 0.08).opacity(0.62 * vis)
                ]),
                startPoint: CGPoint(x: cx, y: cy - chord),
                endPoint: CGPoint(x: cx, y: cy + chord)
            )
        )
        var rim = context
        rim.blendMode = .plusLighter
        rim.stroke(manta(1.02), with: .color(Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.28 * vis)), lineWidth: 1.6)
        rim.stroke(
            Path { p in
                p.move(to: CGPoint(x: cx - span, y: cy + flap * chord * 0.42))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy - chord * 0.56),
                               control: CGPoint(x: cx - span * 0.42, y: cy - chord * 0.98))
                p.addQuadCurve(to: CGPoint(x: cx + span, y: cy + flap * chord * 0.42),
                               control: CGPoint(x: cx + span * 0.42, y: cy - chord * 0.98))
            },
            with: .color(Color(red: 0.7, green: 0.95, blue: 1.0).opacity(0.4 * vis)),
            lineWidth: 1.2
        )
    }

    private func drawFishSchool(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let vis = smoothstep(0.7, 1.4, e) * (1 - smoothstep(IntroTiming.ascent - 0.2, IntroTiming.ascent + 0.5, e))
        guard vis > 0.02 else { return }
        let p = clamp01((e - 0.5) / 5.4)
        let centerX = -w * 0.28 + p * (w * 1.56)
        let centerY = h * 0.6 + sin(e * 0.5) * h * 0.03
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<16 {
            let ox = (Self._fs301[i] - 0.5) * w * 0.34
            let oy = (Self._fs302[i] - 0.5) * h * 0.22
            let depth = 0.4 + 0.6 * Self._fs303[i]
            let l = min(w, h) * 0.016 * (0.7 + 0.7 * depth)
            let fx = centerX + ox + sin(e * 1.4 + Double(i)) * 9
            let fy = centerY + oy + sin(e * 1.1 + Double(i) * 0.7) * 7
            guard fx > -60, fx < w + 60 else { continue }
            let wig = sin(e * 9 + Double(i) * 1.3)
            let colour = mixColour((0.2, 0.72, 0.95), (0.55, 0.95, 1.0), Self._fs304[i])
            let a = vis * (0.28 + 0.42 * depth)
            let body = Path(ellipseIn: CGRect(x: fx - l, y: fy - l * 0.34, width: l * 1.8, height: l * 0.68))
            var tail = Path()
            let ty = wig * l * 0.45
            tail.move(to: CGPoint(x: fx - l * 0.85, y: fy))
            tail.addLine(to: CGPoint(x: fx - l * 1.7, y: fy - l * 0.45 + ty))
            tail.addLine(to: CGPoint(x: fx - l * 1.7, y: fy + l * 0.45 + ty))
            tail.closeSubpath()
            ctx.fill(body, with: .color(colour.opacity(a)))
            ctx.fill(tail, with: .color(colour.opacity(a * 0.8)))
            let eyeR = max(l * 0.1, 0.7)
            ctx.fill(
                Path(ellipseIn: CGRect(x: fx + l * 0.5 - eyeR, y: fy - l * 0.08 - eyeR, width: eyeR * 2, height: eyeR * 2)),
                with: .color(Color.white.opacity(a))
            )
        }
    }

    private func drawJellyfish(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let vis = smoothstep(0.8, 1.6, e) * (1 - smoothstep(IntroTiming.ascent - 0.1, IntroTiming.ascent + 0.6, e))
        guard vis > 0.02 else { return }
        var ctx = context
        ctx.blendMode = .plusLighter
        for n in 0..<2 {
            let side = n == 0 ? 0.15 : 0.85
            let x = w * side + sin(e * 0.4 + Double(n) * 2) * w * 0.03
            let drift = fract(0.2 + Double(n) * 0.5 + e * 0.02)
            let y = h * (1.02 - drift * 0.95)
            let pulse = 0.5 + 0.5 * sin(e * 1.8 + Double(n) * 1.7)
            let bw = min(w, h) * 0.05 * (0.85 + 0.25 * pulse)
            let bh = bw * (0.9 - 0.2 * pulse)
            let colour = mixColour((0.5, 0.72, 1.0), (0.92, 0.6, 0.95), Double(n))
            let a = vis * 0.32
            var bell = Path()
            bell.move(to: CGPoint(x: x - bw, y: y))
            bell.addQuadCurve(to: CGPoint(x: x + bw, y: y), control: CGPoint(x: x, y: y - bh * 2.3))
            bell.addQuadCurve(to: CGPoint(x: x - bw, y: y), control: CGPoint(x: x, y: y + bh * 0.55))
            bell.closeSubpath()
            ctx.fill(
                bell,
                with: .radialGradient(
                    Gradient(colors: [colour.opacity(a), colour.opacity(a * 0.3), .clear]),
                    center: CGPoint(x: x, y: y - bh * 0.6),
                    startRadius: 0,
                    endRadius: bw * 1.5
                )
            )
            ctx.stroke(bell, with: .color(colour.opacity(a * 1.5)), lineWidth: 1)
            for k in 0..<7 {
                let tx = x + (Double(k) / 6 - 0.5) * bw * 1.4
                var t = Path()
                t.move(to: CGPoint(x: tx, y: y))
                let len = bh * (3 + 2 * unitRandom(n * 7 + k, 311))
                var yy = y
                while yy < y + len {
                    let f = (yy - y)
                    let px = tx + sin(e * 3 + f * 0.05 + Double(k)) * bw * 0.28 * (1 - pulse * 0.3)
                    t.addLine(to: CGPoint(x: px, y: yy))
                    yy += 7
                }
                ctx.stroke(t, with: .color(colour.opacity(a * 0.65)), lineWidth: 1)
            }
        }
    }

    private func drawKelp(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let vis = smoothstep(0.4, 1.0, e) * (1 - smoothstep(IntroTiming.ascent, IntroTiming.ascent + 0.7, e))
        guard vis > 0.02 else { return }
        let ctx = context
        for i in 0..<8 {
            let baseX = w * (0.04 + 0.13 * Double(i)) + (Self._kp321[i] - 0.5) * w * 0.04
            let height = h * (0.24 + 0.2 * Self._kp322[i])
            let sway = 0.5 + Self._kp323[i]
            var path = Path()
            path.move(to: CGPoint(x: baseX, y: h + 4))
            let steps = 10
            for s in 1...steps {
                let f = Double(s) / Double(steps)
                let yy = h - height * f
                let xx = baseX + sin(e * sway + f * 3.0 + Double(i)) * (9 + 24 * f)
                path.addLine(to: CGPoint(x: xx, y: yy))
            }
            let a = vis * 0.3
            ctx.stroke(path, with: .color(Color(red: 0.02, green: 0.2, blue: 0.18).opacity(a * 1.7)), lineWidth: 7)
            ctx.stroke(path, with: .color(Color(red: 0.1, green: 0.52, blue: 0.46).opacity(a)), lineWidth: 2.4)
        }
    }

    private func drawFarDust(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let rays = clamp01(0.3 + 0.6 * (1 - smoothstep(0.4, 1.4, e)) + smoothstep(IntroTiming.ascent, 6.1, e))
        let ascentRate = max(0, e - IntroTiming.ascent)
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<30 {
            let r1 = Self._fd55[i]
            let r2 = Self._fd56[i]
            let r3 = Self._fd57[i]
            let x = w * r1 + sin(e * (0.25 + 0.35 * r2) + Double(i)) * 10
            let prog = fract(r2 + e * 0.008 * (0.4 + r3) + ascentRate * ascentRate * 0.3)
            let y = h * prog
            let flicker = 0.5 + 0.5 * sin(e * (1.6 + 2.4 * r3) + Double(i) * 2.1)
            let alpha = rays * flicker * (0.05 + 0.09 * r3)
            guard alpha > 0.01 else { continue }
            let radius = 1.4 + 2.6 * r3
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(red: 0.8, green: 0.97, blue: 1.0).opacity(alpha), .clear]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private func drawFarSnow(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let ascentRate = max(0, e - IntroTiming.ascent)
        let ascentWarp = ascentRate * ascentRate * 0.5
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<24 {
            let r1 = Self._fsnow161[i]
            let r2 = Self._fsnow162[i]
            let prog = fract(r1 + e * 0.008 * (0.4 + r2) + ascentWarp * 0.4)
            let x = w * Self._fsnow163[i] + sin(e * 0.4 + Double(i)) * 5
            let y = h * prog
            let radius = 0.5 + 0.9 * r2
            let alpha = 0.05 + 0.06 * r1
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(Color.white.opacity(alpha))
            )
        }
    }

    private func drawFarBubbles(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let warp = bubbleWarp(e)
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<16 {
            let r1 = Self._fb171[i]
            let r2 = Self._fb172[i]
            let prog = fract(r1 + warp * (0.06 + 0.12 * r2))
            let y = h * (1.08 - prog * 1.16)
            guard y > -40, y < h + 40 else { continue }
            let x = w * Self._fb173[i] + sin(e * 0.9 + Double(i)) * 5
            let radius = 0.8 + 1.8 * r2
            let bubble = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            ctx.fill(bubble, with: .color(Color.white.opacity(0.1 + 0.08 * r2)))
        }
    }

    private func drawThermocline(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let visible = smoothstep(0.5, 0.9, e) * (1 - smoothstep(3.5, 4.0, e))
        guard visible > 0.02 else { return }
        let yBase = h * lerp(0.2, 0.64, smoothstep(0.5, 3.2, e))
        var ctx = context
        ctx.blendMode = .plusLighter
        let step = w / 24
        for band in 0..<3 {
            let fb = Double(band)
            let offset = (fb - 1) * 2.6
            var path = Path()
            path.move(to: CGPoint(x: -10, y: yBase + offset))
            var x = 0.0
            while x <= w + step {
                let y = yBase + offset
                    + sin(x * 0.03 + e * 2.2 + fb * 1.4) * 3.2
                    + sin(x * 0.011 - e * 1.1 + fb) * 5.5
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            let shimmer = 0.05 + 0.045 * sin(e * (7.0 + fb * 2.0) + fb * 2.9)
            let alpha = visible * max(0, shimmer) * (band == 1 ? 1.4 : 0.8)
            guard alpha > 0.004 else { continue }
            ctx.stroke(
                path,
                with: .color(Color(red: 0.7, green: 0.95, blue: 1.0).opacity(alpha)),
                lineWidth: band == 1 ? 1.3 : 0.8
            )
        }
    }
}

private struct NearOceanCanvas: View {
    let e: Double

    // Precomputed per-particle random values — see FarOceanCanvas for rationale.
    // Fish-streaks inner seed = s*37+j where s∈0..<3, j∈0..<12 → seed ∈ 0..<86.
    private static let _cw41:    [Double] = (0..<12).map  { unitRandom($0, 41)  }
    private static let _cw42:    [Double] = (0..<12).map  { unitRandom($0, 42)  }
    private static let _fso90:   [Double] = (0..<3).map   { unitRandom($0, 90)  }
    private static let _fso91:   [Double] = (0..<3).map   { unitRandom($0, 91)  }
    private static let _fso92:   [Double] = (0..<3).map   { unitRandom($0, 92)  }
    private static let _fsi93:   [Double] = (0..<86).map  { unitRandom($0, 93)  }
    private static let _fsi94:   [Double] = (0..<86).map  { unitRandom($0, 94)  }
    private static let _fsi95:   [Double] = (0..<86).map  { unitRandom($0, 95)  }
    private static let _vr71:    [Double] = (0..<260).map { unitRandom($0, 71)  }
    private static let _vr72:    [Double] = (0..<260).map { unitRandom($0, 72)  }
    private static let _vr73:    [Double] = (0..<260).map { unitRandom($0, 73)  }
    private static let _vr74:    [Double] = (0..<260).map { unitRandom($0, 74)  }
    private static let _vr75:    [Double] = (0..<260).map { unitRandom($0, 75)  }
    private static let _vr76:    [Double] = (0..<260).map { unitRandom($0, 76)  }
    private static let _vr77:    [Double] = (0..<260).map { unitRandom($0, 77)  }
    private static let _bio101:  [Double] = (0..<42).map  { unitRandom($0, 101) }
    private static let _bio102:  [Double] = (0..<42).map  { unitRandom($0, 102) }
    private static let _bio103:  [Double] = (0..<42).map  { unitRandom($0, 103) }
    private static let _bio104:  [Double] = (0..<42).map  { unitRandom($0, 104) }
    private static let _bio105:  [Double] = (0..<42).map  { unitRandom($0, 105) }
    private static let _nd181:   [Double] = (0..<22).map  { unitRandom($0, 181) }
    private static let _nd182:   [Double] = (0..<22).map  { unitRandom($0, 182) }
    private static let _nd183:   [Double] = (0..<22).map  { unitRandom($0, 183) }
    private static let _ms61:    [Double] = (0..<46).map  { unitRandom($0, 61)  }
    private static let _ms62:    [Double] = (0..<46).map  { unitRandom($0, 62)  }
    private static let _ms63:    [Double] = (0..<46).map  { unitRandom($0, 63)  }
    private static let _ss151:   [Double] = (0..<16).map  { unitRandom($0, 151) }
    private static let _ss152:   [Double] = (0..<16).map  { unitRandom($0, 152) }
    private static let _ss153:   [Double] = (0..<16).map  { unitRandom($0, 153) }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            drawCausticWeb(&context, size: size)
            drawFishStreaks(&context, size: size)
            drawLightColumn(&context, size: size)
            drawVortexRing4D(&context, size: size)
            drawVortex(&context, size: size)
            drawIconTrace(&context, size: size)
            drawBioluminescence(&context, size: size)
            drawShockwave(&context, size: size)
            drawNearDust(&context, size: size)
            drawMarineSnow(&context, size: size)
            drawBubbles(&context, size: size)
            drawSurfaceSheen(&context, size: size)
            drawChromaticVignette(&context, size: size)
            drawVignette(&context, size: size)
            drawGrain(&context, size: size)
        }
        .scaleEffect(x: 1 + 0.004 * sin(e * 1.9), y: 1 + 0.004 * cos(e * 1.5))
        .rotationEffect(.degrees(0.18 * sin(e * 0.8 + 0.9)))
        .allowsHitTesting(false)
    }

    private func drawCausticWeb(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let intensity = (0.25 + 0.75 * smoothstep(0.5, 1.2, e)) * (1 - smoothstep(5.8, 6.2, e)) + smoothstep(IntroTiming.ascent, 6.0, e) * 0.5
        guard intensity > 0.01 else { return }
        var ctx = context
        ctx.blendMode = .plusLighter
        let step = w / 20
        for k in 0..<12 {
            let baseY = h * (0.04 + 0.085 * Double(k))
            let amp = 8.0 + 13.0 * Self._cw41[k]
            let slope = (Self._cw42[k] - 0.5) * 0.05
            let phase = e * (0.8 + 0.12 * Double(k)) + Double(k) * 1.9
            var path = Path()
            path.move(to: CGPoint(x: -12, y: baseY))
            var x = 0.0
            while x <= w + step {
                let y = baseY + x * slope
                    + sin(x * 0.02 + phase) * amp
                    + sin(x * 0.051 - phase * 1.7) * amp * 0.45
                    + sin(x * 0.013 + phase * 0.6) * amp * 0.3
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            let alpha = intensity * (0.035 + 0.03 * sin(e * 2.1 + Double(k) * 2.7))
            guard alpha > 0 else { continue }
            ctx.stroke(
                path,
                with: .color(Color(red: 0.55, green: 0.9, blue: 1.0).opacity(alpha)),
                lineWidth: 1.6
            )
        }
    }

    private func drawFishStreaks(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        var ctx = context
        ctx.blendMode = .plusLighter
        for s in 0..<3 {
            let startT = 1.15 + Double(s) * 0.62 + 0.2 * Self._fso90[s]
            let p = (e - startT) / 0.95
            guard p > 0, p < 1 else { continue }
            let dir: Double = Self._fso91[s] > 0.5 ? 1 : -1
            let yBase = h * (0.22 + 0.5 * Self._fso92[s])
            let travel = w * 1.45
            let x0 = dir > 0 ? -w * 0.22 : w * 1.22
            let window = sin(p * .pi)
            for j in 0..<12 {
                let seed = s * 37 + j
                let r1 = Self._fsi93[seed]
                let r2 = Self._fsi94[seed]
                let r3 = Self._fsi95[seed]
                let x = x0 + dir * travel * p - dir * (Double(j) * 15 + r1 * 24)
                let y = yBase + sin(p * 10 + Double(j) * 0.9) * 11 + (r2 - 0.5) * 52
                let len = 20 + 20 * r3
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x - dir * len, y: y + sin(Double(j)) * 2.5))
                let alpha = window * (0.18 + 0.26 * r3)
                ctx.stroke(
                    path,
                    with: .color(Color(red: 0.7, green: 0.95, blue: 1.0).opacity(alpha)),
                    lineWidth: 1.4
                )
                let head = 1.5 + r3
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - head, y: y - head, width: head * 2, height: head * 2)),
                    with: .color(Color.white.opacity(alpha * 1.2))
                )
            }
        }
    }

    private func drawVortexRing4D(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let build = smoothstep(1.15, 1.95, e)
        let collapse = smoothstep(2.28, 2.64, e)
        let vis = build * (1 - collapse)
        guard vis > 0.01 else { return }
        let cx = w / 2
        let cy = h / 2
        let base = min(w, h)
        let scale = base * 0.3 * (0.55 + 0.45 * build) * (1 - 0.9 * collapse)
        let aXZ = e * 0.55
        let aYW = e * 0.9
        let aXW = e * 0.32
        let spin = e * 0.4
        let tilt = 0.5
        let cS = cos(spin), sS = sin(spin)
        let cT = cos(tilt), sT = sin(tilt)
        let c1 = cos(aXZ), s1 = sin(aXZ)
        let c2 = cos(aYW), s2 = sin(aYW)
        let c3 = cos(aXW), s3 = sin(aXW)

        let uCount = 48
        let vCount = 7
        let travel = (Int(e * 7) % 6)
        var ctx = context
        ctx.blendMode = .plusLighter

        for j in 0..<vCount {
            let v = Double(j) / Double(vCount) * 2 * .pi
            let cv = cos(v), sv = sin(v)
            var pts: [(x: Double, y: Double, d: Double)] = []
            pts.reserveCapacity(uCount + 1)
            for i in 0...uCount {
                let u = Double(i) / Double(uCount) * 2 * .pi
                var x = cos(u)
                var y = sin(u)
                var z = cv
                var w4 = sv
                let nx = x * c1 - z * s1; let nz = x * s1 + z * c1
                x = nx; z = nz
                let ny = y * c2 - w4 * s2; let nw = y * s2 + w4 * c2
                y = ny; w4 = nw
                let nx2 = x * c3 - w4 * s3; let nw2 = x * s3 + w4 * c3
                x = nx2; w4 = nw2
                let k4 = 2.6 / (2.6 - w4)
                var px = x * k4, py = y * k4, pz = z * k4
                let rx = px * cS + pz * sS; let rz = -px * sS + pz * cS
                px = rx; pz = rz
                let ry = py * cT - pz * sT; let rz2 = py * sT + pz * cT
                py = ry; pz = rz2
                let k3 = 3.2 / (3.2 - pz)
                let sx = cx + px * k3 * scale
                let sy = cy + py * k3 * scale
                let depth = clamp01((w4 + 1) * 0.5) * clamp01((k3 - 0.5) * 0.7 + 0.35)
                pts.append((sx, sy, depth))
            }
            var glow = Path()
            var core = Path()
            for (i, p) in pts.enumerated() {
                let pt = CGPoint(x: p.x, y: p.y)
                if i == 0 { glow.move(to: pt); core.move(to: pt) } else { glow.addLine(to: pt); core.addLine(to: pt) }
            }
            let colour = mixColour((0.3, 0.78, 1.0), (0.7, 0.95, 1.0), Double(j) / Double(vCount))
            ctx.stroke(glow, with: .color(colour.opacity(vis * 0.2)), lineWidth: 6)
            ctx.stroke(core, with: .color(Color(red: 0.9, green: 0.98, blue: 1.0).opacity(vis * 0.5)), lineWidth: 1.2)
            for (i, p) in pts.enumerated() {
                if i % 6 != (travel + j) % 6 { continue }
                let r = 1.0 + 2.4 * p.d
                let a = vis * (0.35 + 0.65 * p.d)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r * 2, y: p.y - r * 2, width: r * 4, height: r * 4)),
                    with: .radialGradient(
                        Gradient(colors: [Color(red: 0.75, green: 0.96, blue: 1.0).opacity(a * 0.5), .clear]),
                        center: CGPoint(x: p.x, y: p.y),
                        startRadius: 0,
                        endRadius: r * 2
                    )
                )
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .color(Color.white.opacity(a))
                )
            }
        }
    }

    private func drawLightColumn(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let build = smoothstep(1.35, 2.45, e)
        let fade = 1 - smoothstep(2.55, 3.15, e)
        let a = build * fade
        guard a > 0.02 else { return }
        let cx = w / 2
        let cy = h / 2
        let colW = min(w, h) * 0.16 * (0.65 + 0.35 * build) * (1 + 0.05 * sin(e * 6))
        var ctx = context
        ctx.blendMode = .plusLighter
        ctx.fill(
            Path(CGRect(x: cx - colW, y: 0, width: colW * 2, height: h)),
            with: .linearGradient(
                Gradient(colors: [
                    .clear,
                    Color(red: 0.55, green: 0.9, blue: 1.0).opacity(0.16 * a),
                    Color(red: 0.85, green: 0.97, blue: 1.0).opacity(0.34 * a),
                    Color(red: 0.55, green: 0.9, blue: 1.0).opacity(0.16 * a),
                    .clear
                ]),
                startPoint: CGPoint(x: cx - colW, y: 0),
                endPoint: CGPoint(x: cx + colW, y: 0)
            )
        )
        let coreR = colW * 1.3
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - coreR, y: cy - coreR, width: coreR * 2, height: coreR * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.3 * a), Color(red: 0.5, green: 0.88, blue: 1.0).opacity(0.12 * a), .clear]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0,
                endRadius: coreR
            )
        )
        for k in 0..<3 {
            let fk = Double(k)
            let ribbonX = cx + sin(e * (1.3 + fk * 0.5) + fk * 2.1) * colW * 0.7
            let rw = colW * (0.12 + 0.05 * fk)
            ctx.fill(
                Path(CGRect(x: ribbonX - rw, y: 0, width: rw * 2, height: h)),
                with: .linearGradient(
                    Gradient(colors: [.clear, Color.white.opacity(0.14 * a), .clear]),
                    startPoint: CGPoint(x: ribbonX - rw, y: 0),
                    endPoint: CGPoint(x: ribbonX + rw, y: 0)
                )
            )
        }
    }

    private func drawVortex(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let fadeIn = smoothstep(0.6, 1.0, e)
        let fadeOut = 1 - smoothstep(2.55, 2.95, e)
        let alpha = fadeIn * fadeOut
        guard alpha > 0.005 else { return }

        let converge = smoothstep(0.82, 2.45, e)
        let cx = w / 2
        let cy = h / 2
        let maxR = hypot(w, h) * 0.5
        let iconHalf = min(w, h) * 0.16
        let edgeBlend = smoothstep(0.78, 0.97, converge)

        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<260 {
            let r1 = Self._vr71[i]
            let r2 = Self._vr72[i]
            let r3 = Self._vr73[i]
            let r4 = Self._vr74[i]
            let r5 = Self._vr75[i]
            let z = Self._vr76[i]
            let incline = 0.35 + 1.05 * Self._vr77[i]

            let startRadius = maxR * (0.38 + 0.9 * r1)
            let cAmt = pow(converge, 0.75 + 0.55 * r4)
            let radius = lerp(startRadius, iconHalf * 1.05, cAmt)
            let wind = log(startRadius / max(radius, 1)) * (1.6 + 1.2 * r3)
            let speed = (0.45 + 1.35 * r3) * (1 - 0.55 * cAmt)
            let a = r2 * .pi * 2 + e * speed + wind

            let px = cos(a) * radius
            let py = sin(a) * radius * cos(incline)
            let pz = sin(a) * sin(incline)
            let persp = 1.55 / (1.55 + pz * 0.6)
            let sx = cx + px * persp
            let sy = cy + py * persp

            let edge = squirclePoint(r2 * .pi * 2 + e * 0.9, half: iconHalf * 1.03)
            let x = lerp(sx, cx + Double(edge.x), edgeBlend)
            let y = lerp(sy, cy + Double(edge.y), edgeBlend)

            let depth = 0.35 + 0.65 * (1 - z)
            let dot = (0.6 + 2.1 * r5) * persp * (0.55 + 0.65 * depth)
            let twinkle = 0.65 + 0.35 * sin(e * 6.5 + Double(i))
            let bright = clamp01((persp - 0.72) * 1.3)
            let colour = mixColour((0.45, 0.9, 1.0), (1.0, 1.0, 1.0), r4)
            let a2 = alpha * twinkle * depth * (0.35 + 0.65 * bright) * (0.4 + 0.6 * r5)
            guard a2 > 0.01 else { continue }

            if r5 > 0.74, cAmt < 0.92 {
                let tx = -sin(a)
                let ty = cos(a) * cos(incline)
                let len = (4 + 7 * r3) * persp
                var streak = Path()
                streak.move(to: CGPoint(x: x, y: y))
                streak.addLine(to: CGPoint(x: x - tx * len, y: y - ty * len))
                ctx.stroke(streak, with: .color(colour.opacity(a2 * 0.45)), lineWidth: max(dot * 0.5, 0.5))
            }
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)),
                with: .color(colour.opacity(a2))
            )
        }
    }

    private func drawIconTrace(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let draw = smoothstep(2.02, 2.52, e)
        let fade = 1 - smoothstep(2.58, 2.9, e)
        let alpha = draw * fade
        guard draw > 0.02, alpha > 0.01 else { return }
        let cx = w / 2
        let cy = h / 2
        let half = min(w, h) * 0.163
        let steps = max(Int(draw * 90), 2)
        let span = draw * .pi * 2
        var path = Path()
        var tip = CGPoint(x: cx, y: cy - half)
        for k in 0...steps {
            let theta = -Double.pi / 2 + span * Double(k) / Double(steps)
            let p = squirclePoint(theta, half: half)
            let point = CGPoint(x: cx + Double(p.x), y: cy + Double(p.y))
            if k == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
            tip = point
        }
        var ctx = context
        ctx.blendMode = .plusLighter
        ctx.stroke(path, with: .color(Color(red: 0.5, green: 0.92, blue: 1.0).opacity(alpha * 0.35)), lineWidth: 7)
        ctx.stroke(path, with: .color(Color.white.opacity(alpha * 0.85)), lineWidth: 1.6)
        if draw < 0.999 {
            let tipR = 3.0
            let glowR = 10.0
            ctx.fill(
                Path(ellipseIn: CGRect(x: tip.x - glowR, y: tip.y - glowR, width: glowR * 2, height: glowR * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(alpha * 0.9), .clear]),
                    center: tip,
                    startRadius: 0,
                    endRadius: glowR
                )
            )
            ctx.fill(
                Path(ellipseIn: CGRect(x: tip.x - tipR, y: tip.y - tipR, width: tipR * 2, height: tipR * 2)),
                with: .color(Color.white.opacity(alpha))
            )
        }
    }

    private func drawBioluminescence(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let visible = smoothstep(0.7, 1.4, e) * (1 - smoothstep(5.85, 6.25, e))
        guard visible > 0.02 else { return }
        let cx = w / 2
        let cy = h / 2
        let maxR = hypot(w, h) * 0.62
        let ascentRate = max(0, e - IntroTiming.ascent)
        let ascentWarp = ascentRate * ascentRate * 0.55
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<42 {
            let r1 = Self._bio101[i]
            let r2 = Self._bio102[i]
            let r3 = Self._bio103[i]
            let r4 = Self._bio104[i]
            let r5 = Self._bio105[i]
            let prog = fract(r2 + e * 0.006 * (0.4 + r3) + ascentWarp * (0.3 + 0.5 * r3))
            var x = w * r1 + sin(e * (0.3 + 0.4 * r3) + Double(i) * 1.9) * 12
            var y = h * prog
            let dx = x - cx
            let dy = y - cy
            let dist = hypot(dx, dy)
            var react = 0.0
            if e > IntroTiming.lock {
                for wv in 0..<2 {
                    if let front = shockFront(e, wave: wv) {
                        let radius = 20 + maxR * front.progress
                        let dd = (dist - radius) / 80
                        react += exp(-dd * dd) * front.fade * (wv == 0 ? 1.0 : 0.55)
                    }
                }
            }
            if react > 0.01, dist > 1 {
                let push = react * 30
                x += dx / dist * push
                y += dy / dist * push
            }
            let flicker = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(e * (1.3 + 2.6 * r3) + Double(i) * 2.4), 2)
            let alpha = visible * (0.06 + 0.12 * flicker * r4) + react * 0.75 * visible
            guard alpha > 0.015 else { continue }
            let radius = (0.9 + 2.0 * r4) * (1 + react * 1.7)
            let colour = mixColour((0.35, 1.0, 0.8), (0.55, 0.92, 1.0), r5)
            if react > 0.08 || r4 > 0.75 {
                let glowR = radius * 3.2
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - glowR, y: y - glowR, width: glowR * 2, height: glowR * 2)),
                    with: .radialGradient(
                        Gradient(colors: [colour.opacity(alpha * 0.55), .clear]),
                        center: CGPoint(x: x, y: y),
                        startRadius: 0,
                        endRadius: glowR
                    )
                )
            }
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(colour.opacity(min(alpha, 0.9)))
            )
        }
    }

    private func drawShockwave(_ context: inout GraphicsContext, size: CGSize) {
        guard e > IntroTiming.lock else { return }
        let w = Double(size.width)
        let h = Double(size.height)
        let cx = w / 2
        let cy = h / 2
        let maxR = hypot(w, h) * 0.62
        let waves: [(delay: Double, speed: Double, strength: Double)] = [
            (0.0, 0.9, 1.0),
            (0.24, 0.95, 0.7),
            (0.1, 1.5, 0.4)
        ]
        for (index, wave) in waves.enumerated() {
            let t0 = IntroTiming.lock + wave.delay
            let raw = (e - t0) / wave.speed
            guard raw > 0, raw < 1 else { continue }
            let p = 1 - pow(1 - raw, 2.3)
            let fade = (1 - raw) * wave.strength
            let radius = 20 + maxR * p
            var lit = context
            lit.blendMode = .plusLighter
            lit.stroke(
                Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)),
                with: .color(Color(red: 0.6, green: 0.93, blue: 1.0).opacity(fade * 0.3)),
                lineWidth: 16 * fade + 2
            )
            lit.stroke(
                Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)),
                with: .color(Color.white.opacity(fade * 0.55)),
                lineWidth: 2 * fade + 0.6
            )
            let halo = radius + 12 * fade + 6
            lit.stroke(
                Path(ellipseIn: CGRect(x: cx - halo, y: cy - halo, width: halo * 2, height: halo * 2)),
                with: .color(Color(red: 0.4, green: 0.85, blue: 1.0).opacity(fade * 0.12)),
                lineWidth: 22 * fade + 3
            )
            if index < 2 {
                let inner = radius - (14 * fade + 5)
                if inner > 0 {
                    context.stroke(
                        Path(ellipseIn: CGRect(x: cx - inner, y: cy - inner, width: inner * 2, height: inner * 2)),
                        with: .color(Color(red: 0.0, green: 0.1, blue: 0.22).opacity(fade * 0.3)),
                        lineWidth: 10 * fade + 1.5
                    )
                }
            }
        }
    }

    private func drawNearDust(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let rays = clamp01(0.35 + 0.65 * (1 - smoothstep(0.4, 1.4, e)) + smoothstep(IntroTiming.ascent, 6.1, e))
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<22 {
            let r1 = Self._nd181[i]
            let r2 = Self._nd182[i]
            let r3 = Self._nd183[i]
            let x = w * r1 + sin(e * (0.3 + 0.4 * r2) + Double(i)) * 14
            let y = h * (0.05 + 0.7 * fract(r2 + e * 0.01 * (0.4 + r3)))
            let flicker = 0.5 + 0.5 * sin(e * (2.0 + 3.0 * r3) + Double(i) * 2.1)
            let depthFade = 1 - y / h * 0.7
            let alpha = rays * flicker * depthFade * (0.1 + 0.14 * r3)
            guard alpha > 0.01 else { continue }
            let radius = 0.7 + 1.5 * r3
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(Color(red: 0.85, green: 0.98, blue: 1.0).opacity(alpha))
            )
        }
    }

    private func drawMarineSnow(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let ascentRate = max(0, e - IntroTiming.ascent)
        let ascentWarp = ascentRate * ascentRate * 0.9
        var ctx = context
        ctx.blendMode = .plusLighter
        for i in 0..<46 {
            let r1 = Self._ms61[i]
            let r2 = Self._ms62[i]
            let layer = 0.3 + 0.7 * r2
            let prog = fract(r1 + e * 0.012 * (0.5 + r2) + ascentWarp * layer * 0.6)
            let x = w * Self._ms63[i] + sin(e * 0.6 + Double(i)) * 7 * layer
            let y = h * prog
            let radius = (0.5 + 1.3 * r2) * (0.6 + 0.6 * layer)
            let streak = min(ascentRate * 30 * layer, 42)
            let alpha = (0.09 + 0.09 * r1) * layer
            if streak > 1 {
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + streak))
                ctx.stroke(path, with: .color(Color.white.opacity(alpha)), lineWidth: radius)
            } else {
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(Color.white.opacity(alpha))
                )
            }
        }
    }

    private func drawBubbles(_ context: inout GraphicsContext, size: CGSize) {
        let warp = bubbleWarp(e)
        let rate = bubbleWarpRate(e)
        var ctx = context
        ctx.blendMode = .plusLighter
        drawBubblePlane(&ctx, size: size, count: 26, salt: 300, sizeLo: 1.0, sizeHi: 3.4, alphaScale: 0.7, speedScale: 0.75, warp: warp, rate: rate, detailed: false)
        drawBubblePlane(&ctx, size: size, count: 16, salt: 340, sizeLo: 3.0, sizeHi: 7.2, alphaScale: 1.0, speedScale: 1.15, warp: warp, rate: rate, detailed: true)
    }

    private func drawBubblePlane(
        _ ctx: inout GraphicsContext,
        size: CGSize,
        count: Int,
        salt: Int,
        sizeLo: Double,
        sizeHi: Double,
        alphaScale: Double,
        speedScale: Double,
        warp: Double,
        rate: Double,
        detailed: Bool
    ) {
        let w = Double(size.width)
        let h = Double(size.height)
        for i in 0..<count {
            let layer = unitRandom(i, salt + 1)
            let baseSpeed = (0.12 + 0.5 * layer) * speedScale
            let prog = fract(unitRandom(i, salt + 2) + warp * baseSpeed)
            let y = h * (1.1 - prog * 1.2)
            guard y > -70, y < h + 70 else { continue }
            let sway = sin(e * (1.1 + 0.6 * layer) + Double(i) * 1.3) * (5 + 6 * layer)
            let x = w * unitRandom(i, salt + 3) + sway
            let radius = sizeLo + (sizeHi - sizeLo) * layer
            let streak = min((rate - 1) * radius * 1.8, 58.0)
            let rect = CGRect(
                x: x - radius,
                y: y - radius - streak,
                width: radius * 2,
                height: radius * 2 + streak
            )
            let bubble = Path(ellipseIn: rect)
            let strength = (0.2 + 0.3 * layer) * alphaScale
            ctx.fill(bubble, with: .color(Color.white.opacity(0.07 * strength * 4)))
            ctx.stroke(bubble, with: .color(Color.white.opacity(strength)), lineWidth: detailed ? 0.9 : 0.6)
            if detailed {
                let hl = radius * 0.35
                ctx.fill(
                    Path(ellipseIn: CGRect(
                        x: x - radius * 0.4 - hl / 2,
                        y: y - radius * 0.45 - streak - hl / 2,
                        width: hl,
                        height: hl
                    )),
                    with: .color(Color.white.opacity(strength * 0.9))
                )
                let under = radius * 0.2
                ctx.fill(
                    Path(ellipseIn: CGRect(
                        x: x + radius * 0.3 - under / 2,
                        y: y + radius * 0.35 - under / 2,
                        width: under,
                        height: under
                    )),
                    with: .color(Color(red: 0.6, green: 0.93, blue: 1.0).opacity(strength * 0.5))
                )
            }
        }
    }

    private func drawSurfaceSheen(_ context: inout GraphicsContext, size: CGSize) {
        let visible = smoothstep(5.52, 6.0, e)
        guard visible > 0.02 else { return }
        let w = Double(size.width)
        let h = Double(size.height)
        var ctx = context
        ctx.blendMode = .plusLighter
        let windowY = -h * 0.25 + visible * h * 0.3
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(0.5 * visible),
                    Color(red: 0.65, green: 0.93, blue: 1.0).opacity(0.28 * visible),
                    .clear
                ]),
                center: CGPoint(x: w / 2, y: windowY),
                startRadius: 0,
                endRadius: w * 0.95
            )
        )
        let drop = (1 - visible) * h * 0.14
        for k in 0..<4 {
            let fk = Double(k)
            let baseY = h * (0.045 + 0.052 * fk) + drop
            var path = Path()
            path.move(to: CGPoint(x: -12, y: baseY))
            var x = 0.0
            let step = w / 26
            while x <= w + step {
                let y = baseY
                    + sin(x * 0.021 - e * 3.1 + fk * 1.7) * (4 + 3 * fk)
                    + sin(x * 0.043 + e * 2.3 + fk) * (2.5 + 1.5 * fk)
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            let a = visible * (0.3 - 0.055 * fk)
            ctx.stroke(path, with: .color(Color.white.opacity(a * 0.4)), lineWidth: 6)
            ctx.stroke(path, with: .color(Color.white.opacity(a)), lineWidth: 1.8)
        }
        for i in 0..<16 {
            let r1 = Self._ss151[i]
            let r2 = Self._ss152[i]
            let r3 = Self._ss153[i]
            let x = w * r1
            let y = h * (0.03 + 0.22 * r2) + drop
            let tw = pow(0.5 + 0.5 * sin(e * (5 + 5 * r3) + Double(i) * 2.2), 3)
            let a = visible * tw * 0.7
            guard a > 0.03 else { continue }
            let r = 0.8 + 1.6 * r3
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(Color.white.opacity(a))
            )
        }
    }

    private func drawChromaticVignette(_ context: inout GraphicsContext, size: CGSize) {
        let release = 1 - smoothstep(5.6, 6.2, e)
        guard release > 0.02 else { return }
        let w = Double(size.width)
        let h = Double(size.height)
        let edge = hypot(w, h) * 0.62
        var ctx = context
        ctx.blendMode = .plusLighter
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [.clear, .clear, Color(red: 0.2, green: 0.85, blue: 1.0).opacity(0.05 * release)]),
                center: CGPoint(x: w * 0.44, y: h * 0.42),
                startRadius: min(w, h) * 0.3,
                endRadius: edge
            )
        )
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [.clear, .clear, Color(red: 0.85, green: 0.3, blue: 0.9).opacity(0.035 * release)]),
                center: CGPoint(x: w * 0.56, y: h * 0.58),
                startRadius: min(w, h) * 0.3,
                endRadius: edge
            )
        )
    }

    private func drawVignette(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let release = 1 - smoothstep(5.5, 6.2, e)
        let alpha = (0.32 + 0.28 * smoothstep(0.2, 0.9, e)) * release
        guard alpha > 0.01 else { return }
        let centre = CGPoint(x: w / 2, y: h / 2)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [.clear, .clear, Color.black.opacity(alpha)]),
                center: centre,
                startRadius: min(w, h) * 0.3,
                endRadius: hypot(w, h) * 0.62
            )
        )
    }

    private func drawGrain(_ context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let frame = Int(e * 24)
        var ctx = context
        ctx.blendMode = .plusLighter
        for g in 0..<90 {
            let seed = g &+ frame &* 97
            let x = w * unitRandom(seed, 211)
            let y = h * unitRandom(seed, 212)
            let a = 0.008 + 0.014 * unitRandom(seed, 213)
            let r = 0.5 + 0.5 * unitRandom(seed, 214)
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(Color.white.opacity(a))
            )
        }
    }
}


struct RootLaunchContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @AppStorage(DiveIntroConfig.versionStorageKey) private var lastIntroShownVersion = ""
    @State private var introRunCount: Int = 0

    private var shouldShowIntro: Bool {
        lastIntroShownVersion != DiveIntroConfig.currentVersion
    }

    var body: some View {
        content()
            .environment(\.introVisible, shouldShowIntro)
            .overlay {
                if shouldShowIntro {
                    DiveIntroView {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            lastIntroShownVersion = DiveIntroConfig.currentVersion
                        }
                    }
                    .preferredColorScheme(.dark)
                    .id(introRunCount)
                    .transition(.opacity)
                    .ignoresSafeArea()
                    .zIndex(999)
                }
            }
            .onChange(of: lastIntroShownVersion) { _, newValue in
                if newValue == DiveIntroConfig.replayValue { introRunCount += 1 }
            }
    }
}
