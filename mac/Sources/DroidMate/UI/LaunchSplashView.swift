import SwiftUI

/// First-launch brand moment — multi-beat choreography, then hand off cleanly.
/// Only shown when the host decides (once). Respects Reduce Motion. Click / space / Esc skips.
struct LaunchSplashView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Choreography state (staged, not one-shot)
    @State private var bgDim = false
    @State private var ring1 = false
    @State private var ring2 = false
    @State private var ring3 = false
    @State private var iconIn = false
    @State private var iconSettle = false
    @State private var glowPulse = false
    @State private var titleIn = false
    @State private var taglineIn = false
    @State private var ruleIn = false
    @State private var sparkle = false
    @State private var exiting = false
    @State private var finished = false
    @State private var playTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            background
                .opacity(bgDim ? 1 : 0)

            // Expanding brand rings
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(ringOpacity(i)),
                            lineWidth: i == 0 ? 1.4 : 1.0
                        )
                        .frame(width: ringSize(i), height: ringSize(i))
                        .scaleEffect(ringScale(i))
                        .opacity(ringShown(i) ? 1 : 0)
                }

                // Soft bloom
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(.sRGB, red: 0.55, green: 0.38, blue: 1.0,
                                      opacity: glowPulse ? 0.42 : 0.12),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)
                    .scaleEffect(glowPulse ? 1.12 : 0.85)
                    .blur(radius: 6)

                // Orbiting spark dots (subtle)
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(sparkle ? 0.55 : 0))
                        .frame(width: 3.5, height: 3.5)
                        .offset(sparkOffset(i))
                        .blur(radius: 0.3)
                }

                BrandMark(size: 96)
                    .scaleEffect(iconIn ? (iconSettle ? 1.0 : 1.06) : 0.55)
                    .opacity(iconIn ? 1 : 0)
                    .rotationEffect(.degrees(iconIn ? 0 : -12))
                    .shadow(
                        color: Color(.sRGB, red: 0.40, green: 0.28, blue: 0.95,
                                     opacity: iconIn ? 0.40 : 0),
                        radius: iconSettle ? 28 : 40,
                        y: 12
                    )
            }
            .offset(y: -28)
            .opacity(exiting ? 0 : 1)
            .scaleEffect(exiting ? 0.94 : 1.0)
            .offset(y: exiting ? -12 : 0)

            // Wordmark stack
            VStack(spacing: 10) {
                Spacer().frame(height: 148)

                Text("DroidMate")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .tracking(-0.5)
                    .opacity(titleIn ? 1 : 0)
                    .offset(y: titleIn ? 0 : 16)
                    .blur(radius: titleIn ? 0 : 4)

                Text("Your phone. On your Mac.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .opacity(taglineIn ? 1 : 0)
                    .offset(y: taglineIn ? 0 : 10)

                // Accent rule
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color(.sRGB, red: 0.65, green: 0.5, blue: 1.0, opacity: 0.85),
                                Color.clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: ruleIn ? 56 : 0, height: 2)
                    .opacity(ruleIn ? 1 : 0)
                    .padding(.top, 4)
            }
            .opacity(exiting ? 0 : 1)
            .offset(y: exiting ? 8 : 0)

            // Skip hint (quiet)
            VStack {
                Spacer()
                Text("Click to skip")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(titleIn ? 0.28 : 0))
                    .padding(.bottom, 22)
            }
        }
        .opacity(exiting ? 0 : 1)
        .allowsHitTesting(!finished)
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .focusable()
        .onKeyPress(.space) { skip(); return .handled }
        .onKeyPress(.escape) { skip(); return .handled }
        .onAppear { play() }
        .onDisappear { playTask?.cancel() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("DroidMate")
    }

    // MARK: - Rings helpers

    private func ringShown(_ i: Int) -> Bool {
        switch i {
        case 0: return ring1
        case 1: return ring2
        default: return ring3
        }
    }

    private func ringSize(_ i: Int) -> CGFloat {
        switch i {
        case 0: return 118
        case 1: return 150
        default: return 186
        }
    }

    private func ringScale(_ i: Int) -> CGFloat {
        ringShown(i) ? 1.0 : 0.72
    }

    private func ringOpacity(_ i: Int) -> Double {
        switch i {
        case 0: return 0.28
        case 1: return 0.16
        default: return 0.10
        }
    }

    private func sparkOffset(_ i: Int) -> CGSize {
        let base: CGFloat = sparkle ? 72 : 40
        let angle = Double(i) * (.pi * 2 / 6) - .pi / 2
        return CGSize(width: cos(angle) * base, height: sin(angle) * base)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.05, green: 0.04, blue: 0.12, opacity: 1),
                    Color(.sRGB, red: 0.12, green: 0.08, blue: 0.30, opacity: 1),
                    Color(.sRGB, red: 0.08, green: 0.06, blue: 0.18, opacity: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(.sRGB, red: 0.42, green: 0.28, blue: 0.98, opacity: 0.32),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.78, y: 0.22),
                startRadius: 10,
                endRadius: 340
            )

            RadialGradient(
                colors: [
                    Color(.sRGB, red: 0.60, green: 0.20, blue: 0.85, opacity: 0.22),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.18, y: 0.82),
                startRadius: 8,
                endRadius: 300
            )

            // Fine grain via noise-like dots (static, cheap)
            GeometryReader { geo in
                Canvas { ctx, size in
                    for i in 0..<80 {
                        let x = CGFloat((i * 47) % 97) / 97 * size.width
                        let y = CGFloat((i * 31) % 89) / 89 * size.height
                        let r = CGFloat(0.6 + Double(i % 3) * 0.3)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                            with: .color(.white.opacity(0.04))
                        )
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Sequence

    private func play() {
        playTask?.cancel()
        playTask = Task { @MainActor in
            if reduceMotion {
                bgDim = true
                iconIn = true
                iconSettle = true
                titleIn = true
                taglineIn = true
                ruleIn = true
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await exitAndFinish(durationMs: 180)
                return
            }

            // Beat 1 — stage lights up
            withAnimation(.easeOut(duration: 0.45)) { bgDim = true }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, !finished else { return }

            // Beat 2 — rings expand in cascade
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { ring1 = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.spring(response: 0.58, dampingFraction: 0.80)) { ring2 = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.spring(response: 0.62, dampingFraction: 0.82)) { ring3 = true }

            // Beat 3 — icon pops in, overshoots, settles
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.spring(response: 0.52, dampingFraction: 0.68)) { iconIn = true }
            withAnimation(.easeOut(duration: 0.7)) { glowPulse = true }
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(.spring(response: 0.40, dampingFraction: 0.86)) { iconSettle = true }

            // Beat 4 — sparkles drift out
            withAnimation(.spring(response: 0.70, dampingFraction: 0.75)) { sparkle = true }

            // Beat 5 — wordmark cascade
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(response: 0.48, dampingFraction: 0.88)) { titleIn = true }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.spring(response: 0.50, dampingFraction: 0.90)) { taglineIn = true }
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { ruleIn = true }

            // Beat 6 — hold, then exit
            try? await Task.sleep(for: .milliseconds(720))
            guard !Task.isCancelled, !finished else { return }
            await exitAndFinish(durationMs: 420)
        }
    }

    private func skip() {
        guard !finished else { return }
        playTask?.cancel()
        playTask = Task { @MainActor in
            await exitAndFinish(durationMs: reduceMotion ? 120 : 260)
        }
    }

    @MainActor
    private func exitAndFinish(durationMs: Int) async {
        guard !finished else { return }
        // Coordinated exit: content lifts slightly, opacity only — no layout thrash.
        withAnimation(.easeInOut(duration: Double(durationMs) / 1000.0)) {
            exiting = true
            glowPulse = false
            sparkle = false
        }
        try? await Task.sleep(for: .milliseconds(durationMs))
        guard !finished else { return }
        finished = true
        // Host removes us without further animation (avoids double-transition jank).
        onFinished()
    }
}
