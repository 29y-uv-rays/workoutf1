import UIKit

enum Haptics {
    static func light() {
        guard !UxReduceMotion else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Reduce Motion doubles as "reduce feedback" here: no impact haptics when the user asked for less motion.
    private static var UxReduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
}
