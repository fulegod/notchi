import SwiftUI

struct SessionSpriteView: View {
    let state: NotchiState
    let isSelected: Bool
    var onTap: (() -> Void)? = nil

    private var bobAmplitude: CGFloat {
        guard state.bobAmplitude > 0 else { return 0 }
        return isSelected ? state.bobAmplitude : state.bobAmplitude * 0.67
    }

    private static let sobTrembleAmplitude: CGFloat = 0.2
    private static let walkRange: CGFloat = 42   // ~1.5 squares
    private static let walkDuration: Double = 5.0

    private var isWalking: Bool {
        state.canWalk
    }

    private func walkPhase(at date: Date) -> Double {
        guard isWalking else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        return (t / Self.walkDuration).truncatingRemainder(dividingBy: 1.0)
    }

    private func walkOffset(phase: Double) -> CGFloat {
        guard isWalking else { return 0 }
        let wave = sin(phase * .pi * 2) * 0.5 + 0.5
        return wave * Self.walkRange
    }

    private func isMovingRight(phase: Double) -> Bool {
        // Moving right when sin is increasing (first half of cycle)
        let derivative = cos(phase * .pi * 2)
        return derivative > 0
    }

    private var shouldAnimate: Bool {
        state.task != .idle
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shouldAnimate)) { timeline in
            let phase = walkPhase(at: timeline.date)
            let movingRight = isMovingRight(phase: phase)

            SpriteSheetView(
                spriteSheet: state.spriteSheetName,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: shouldAnimate
            )
            .frame(width: 44, height: 44)
            .scaleEffect(x: isWalking ? (movingRight ? 1 : -1) : 1, y: 1, anchor: .center)
            .offset(
                x: walkOffset(phase: phase) + trembleOffset(at: timeline.date, amplitude: state.emotion == .sob ? Self.sobTrembleAmplitude : 0),
                y: bobOffset(at: timeline.date, duration: state.bobDuration, amplitude: bobAmplitude)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}
