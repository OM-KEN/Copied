import SwiftUI
import Observation

@Observable
final class ToastCopyComboPresentation {
    static let displayDuration: TimeInterval = 1.15

    var count = 0
    var motionActive = false
    var entranceSuppressed = false
    var entranceTrigger = 0
    var isPendingReplacement = false
    var isDismissing = false
    var owner = 0
    @ObservationIgnored var motion = CopyEchoMotion()
    @ObservationIgnored private let now: () -> TimeInterval
    private var trajectory: CopyEchoTrajectory?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
#if COPIED_TESTING
    @ObservationIgnored var testingResponseCount = 0
    @ObservationIgnored var testingEntranceProjection = ToastEntranceProjection.identity
    @ObservationIgnored var testingEchoGraphInstallCount = 0
#endif

    var isVisible: Bool { count >= 3 }
    var hasEcho: Bool { count >= 2 || motionActive }
    var badgeText: String { String(localized: "连击×\(count)") }

    @discardableResult
    func activate(
        _ hit: ClipboardCopyCombo.Hit,
        reduceMotion: Bool,
        mayStartMotion: Bool = true
    ) -> Bool {
        count = hit.count
        entranceSuppressed = true
        if reduceMotion {
            stopMotion()
            return false
        }
        // A busy event continues the current position and velocity. Only a late
        // event arriving after motion ended is prevented from starting anew.
        guard motionActive || mayStartMotion else { return false }
        let time = now()
        let current = sample(at: time)
        let direction = trajectory.map { $0.target.swing > 0 ? -1.0 : 1.0 } ?? hit.direction
        trajectory = CopyEchoTrajectory(
            startedAt: time, initial: current,
            target: CopyEchoMotion(swing: direction * hit.impulse * 12, trail: 1, spread: 1)
        )
        motion = current.motion
        motionActive = true
#if COPIED_TESTING
        testingResponseCount &+= 1
#endif
        return true
    }

    func sample(at time: TimeInterval? = nil) -> CopyEchoSample {
        trajectory?.sample(at: time ?? now()) ?? CopyEchoSample()
    }

    func clear(preservingMotion: Bool = false) {
        count = 0
        motionActive = false
        trajectory = nil
        isDismissing = false
        // Only a new presentation may restore the ordinary entrance. Its old
        // progress has been cancelled and must not resume when the counter ends.
        if !preservingMotion { motion = CopyEchoMotion() }
    }

    func stopMotion() {
        trajectory = nil
        motionActive = false
        motion = CopyEchoMotion()
    }
}

struct CopyEchoMotion: Equatable {
    var swing = 0.0
    var trail = 0.0
    var spread = 0.0
}

struct CopyEchoSample {
    var motion = CopyEchoMotion()
    var velocity = CopyEchoMotion()
}

private struct CopyEchoTrajectory {
    private static let spring = Spring(response: 0.22, dampingRatio: 0.86)
    private static let holdDuration: TimeInterval = 0.08

    let startedAt: TimeInterval
    let initial: CopyEchoSample
    let target: CopyEchoMotion

    func sample(at time: TimeInterval) -> CopyEchoSample {
        let elapsed = max(0, time - startedAt)
        let held = advance(initial, toward: target, time: min(elapsed, Self.holdDuration))
        guard elapsed > Self.holdDuration else { return held }
        return advance(held, toward: CopyEchoMotion(), time: elapsed - Self.holdDuration)
    }

    private func advance(
        _ state: CopyEchoSample, toward target: CopyEchoMotion, time: TimeInterval
    ) -> CopyEchoSample {
        func channel(_ value: Double, _ velocity: Double, _ goal: Double) -> (Double, Double) {
            (value + Self.spring.value(target: goal - value, initialVelocity: velocity, time: time),
             Self.spring.velocity(target: goal - value, initialVelocity: velocity, time: time))
        }
        let swing = channel(state.motion.swing, state.velocity.swing, target.swing)
        let trail = channel(state.motion.trail, state.velocity.trail, target.trail)
        let spread = channel(state.motion.spread, state.velocity.spread, target.spread)
        return CopyEchoSample(
            motion: CopyEchoMotion(swing: swing.0, trail: trail.0, spread: spread.0),
            velocity: CopyEchoMotion(swing: swing.1, trail: trail.1, spread: spread.1)
        )
    }
}

struct ToastCopyComboEffect: ViewModifier {
    let presentation: ToastCopyComboPresentation
    let reduceMotion: Bool
    let owner: Int

    func body(content: Content) -> some View {
        let presentation = presentation
        let reduceMotion = reduceMotion
        let owner = owner
        if !presentation.hasEcho {
            content
        } else if reduceMotion {
            CopyEchoComposition(card: content, presentation: presentation, reduceMotion: true,
                                owner: owner, motion: CopyEchoMotion())
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60,
                                    paused: !presentation.motionActive || presentation.isDismissing)) { _ in
                let motion = presentation.isDismissing ? presentation.motion : presentation.sample().motion
                CopyEchoComposition(card: content, presentation: presentation, reduceMotion: reduceMotion,
                                    owner: owner, motion: motion)
            }
#if COPIED_TESTING
            .onAppear { presentation.testingEchoGraphInstallCount += 1 }
#endif
        }
    }
}

private struct CopyEchoComposition<Card: View>: View {
    let card: Card
    let presentation: ToastCopyComboPresentation
    let reduceMotion: Bool
    let owner: Int
    let motion: CopyEchoMotion

    var body: some View {
        let currentMotion = presentation.isDismissing ? presentation.motion : motion
        let active = presentation.hasEcho && presentation.motionActive && !reduceMotion
        let swing = active ? currentMotion.swing : 0
        let spread = active ? currentMotion.spread : 0
        return card
            .rotation3DEffect(.degrees(swing * 1.3), axis: (x: 0, y: 1, z: 0), perspective: 0.25)
            .rotationEffect(.degrees(-swing * 0.13))
            // Keep every tilted corner below the screen's top edge.
            .offset(x: swing, y: abs(swing) * 0.5)
            .background {
                if active {
                    ForEach(1...3, id: \.self) { index in
                        CopyEchoOutline()
                            .scaleEffect(1 - Double(index) * 0.012 * spread)
                            .rotationEffect(.degrees(-swing * Double(index) * 0.12))
                            .offset(
                                x: -swing * Double(index) * 1.1,
                                y: Double(index) * (3 * spread + abs(swing) * 0.45)
                            )
                            .opacity(currentMotion.trail * (0.72 - Double(index) * 0.14))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if presentation.isVisible {
                    Text(presentation.badgeText)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .frame(minWidth: 48, minHeight: 28)
                        .background(.regularMaterial, in: Capsule())
                        .scaleEffect(1 + 0.07 * spread)
                        .rotationEffect(.degrees(-swing * 0.5))
                        .offset(x: -12 + swing * 0.4, y: 14)
                        .allowsHitTesting(false)
                        .accessibilityLabel(String(localized: "连续复制 \(presentation.count) 次"))
                }
            }
            .onChange(of: motion) {
                // Retain only scalar motion, never a view or rendered clipboard body.
                // The active host renders one continuous, retargetable trajectory.
                guard presentation.owner == owner, presentation.motionActive,
                      !presentation.isDismissing else { return }
                presentation.motion = motion
            }
    }
}

/// Decorative outlines only: no clipboard body, live material, controls, or thumbnails.
private struct CopyEchoOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(.primary.opacity(0.14))
            .overlay {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.4))
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(.primary.opacity(0.5)).frame(height: 7)
                        Capsule().fill(.secondary.opacity(0.4)).frame(maxWidth: 100).frame(height: 5)
                    }
                }
                .padding(16)
            }
    }
}
