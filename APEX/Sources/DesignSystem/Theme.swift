import SwiftUI

// MARK: - Colour tokens

enum Theme {
    static let background = Color(hex: "0A0A0C")
    static let surface = Color(hex: "15151A")
    static let border = Color(hex: "26262E")
    static let text = Color(hex: "F5F5F7")
    static let secondaryText = Color(hex: "8E8E99")
    static let purple = Color(hex: "B14AED")
    static let green = Color(hex: "2FD158")
    static let yellow = Color(hex: "FFD60A")
    static let grey = Color(hex: "5A5A66")
    static let mapRouteLine = Color(hex: "F5F5F7").opacity(0.85)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}

// MARK: - Timing colours

enum SectorColor: String, Codable, Sendable, CaseIterable {
    case purple, green, yellow, grey

    var color: Color {
        switch self {
        case .purple: return Theme.purple
        case .green:  return Theme.green
        case .yellow: return Theme.yellow
        case .grey:   return Theme.grey
        }
    }

    var shortLabel: String {
        switch self {
        case .purple: return "P"
        case .green:  return "G"
        case .yellow: return "Y"
        case .grey:   return "—"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .purple: return "purple, new route record"
        case .green:  return "green, improved on your last lap"
        case .yellow: return "yellow, slower than your last lap"
        case .grey:   return "grey, no valid time"
        }
    }

    var glyph: String {
        switch self {
        case .purple: return "●"
        case .green:  return "○"
        case .yellow: return "△"
        case .grey:   return "○"
        }
    }

    /// Non-colour indicator glyph for accessibility/legend (always visible, high-contrast shape).
    var legendGlyph: String {
        switch self {
        case .purple: return "◆"
        case .green:  return "●"
        case .yellow: return "▲"
        case .grey:   return "■"
        }
    }
}

// MARK: - Timing board fonts

extension Font {
    static let timingBoard = Font.system(size: 34, weight: .medium, design: .monospaced)
    static let timingBoardSmall = Font.system(size: 22, weight: .medium, design: .monospaced)
    static let sectorTag = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let labelCaps = Font.system(size: 12, weight: .medium).lowercaseSmallCaps()
}

extension View {
    func monospacedDigits() -> some View {
        modifier(MonospacedDigitModifier())
    }
}

private struct MonospacedDigitModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.timingBoardSmall).contentTransition(.numericText())
    }
}

// MARK: - Panels

struct Panel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Time formatting

enum TimeFormat {
    static func delta(_ value: Double) -> String {
        let sign = value < -0.005 ? "-" : (value > 0.005 ? "+" : "±")
        let total = abs(value)
        let minutes = Int(total / 60.0)
        let seconds = total - Double(minutes) * 60.0
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 100.0 + 0.5).clamped(to: 0...99)
        return String(format: "%@%02d:%02d.%02d", sign, minutes, whole, tenths)
    }

    static func absolute(_ value: Double) -> String {
        guard value >= 0 else { return "—" }
        let minutes = Int(value / 60.0)
        let seconds = value - Double(minutes) * 60.0
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 100.0 + 0.5).clamped(to: 0...99)
        return String(format: "%02d:%02d.%02d", minutes, whole, tenths)
    }

    static func totalSeconds(_ value: Double) -> String {
        guard value >= 0 else { return "—" }
        return String(format: "%.2fs", value)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.max(range.lowerBound, Swift.min(range.upperBound, self)) }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.max(range.lowerBound, Swift.min(range.upperBound, self)) }
}

// MARK: - Activity type

enum ActivityType: String, Codable, CaseIterable, Sendable {
    case run, walk, cycle

    var displayName: String { rawValue.capitalized }

    var plausibilityCapMps: Double {
        switch self {
        case .run:   return 12.0
        case .walk:  return 5.0
        case .cycle: return 25.0
        }
    }
}
