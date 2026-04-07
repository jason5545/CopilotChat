import SwiftUI

// MARK: - Carbon Design System
// A dark, refined aesthetic for developer-focused AI chat.
// Warm amber accent · Editorial typography · Atmospheric depth

// MARK: - Color Palette

extension Color {
    // Base layers
    static let carbonBlack = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let carbonSurface = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let carbonElevated = Color(red: 0.153, green: 0.153, blue: 0.165)
    static let carbonBorder = Color(red: 0.247, green: 0.247, blue: 0.275)

    // Text hierarchy
    static let carbonText = Color(red: 0.980, green: 0.980, blue: 0.980)
    static let carbonTextSecondary = Color(red: 0.631, green: 0.631, blue: 0.667)
    static let carbonTextTertiary = Color(red: 0.443, green: 0.443, blue: 0.478)

    // Accent — warm amber
    static let carbonAccent = Color(red: 0.961, green: 0.620, blue: 0.043)
    static let carbonAccentMuted = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.15)

    // User message — subtle warm tint
    static let carbonUserBubble = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.12)
    static let carbonUserBorder = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.25)

    // Semantic
    static let carbonSuccess = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let carbonError = Color(red: 0.973, green: 0.443, blue: 0.443)
    static let carbonWarning = Color(red: 0.984, green: 0.749, blue: 0.141)

    // Code block
    static let carbonCodeBg = Color(red: 0.063, green: 0.063, blue: 0.075)
}

// MARK: - Typography

extension Font {
    /// Serif (New York) — used for AI assistant prose
    static func carbonSerif(_ style: TextStyle, weight: Weight = .regular) -> Font {
        .system(style, design: .serif, weight: weight)
    }

    /// Monospace (SF Mono) — used for UI chrome, labels, code
    static func carbonMono(_ style: TextStyle, weight: Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// Sans (SF Pro) — used for user input, general text
    static func carbonSans(_ style: TextStyle, weight: Weight = .regular) -> Font {
        .system(style, weight: weight)
    }
}

// MARK: - Spacing

enum Carbon {
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16

    static let spacingTight: CGFloat = 4
    static let spacingBase: CGFloat = 8
    static let spacingRelaxed: CGFloat = 12
    static let spacingLoose: CGFloat = 16
    static let spacingWide: CGFloat = 24

    static let messagePaddingH: CGFloat = 16
    static let messagePaddingV: CGFloat = 12
    static let accentBarWidth: CGFloat = 2.5
}

// MARK: - View Modifiers

struct CarbonBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.carbonBlack)
    }
}

struct CarbonCardStyle: ViewModifier {
    var filled: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(Carbon.messagePaddingH)
            .background(filled ? Color.carbonSurface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                    .stroke(Color.carbonBorder.opacity(0.5), lineWidth: 0.5)
            )
    }
}

extension View {
    func carbonBackground() -> some View {
        modifier(CarbonBackground())
    }

    func carbonCard(filled: Bool = true) -> some View {
        modifier(CarbonCardStyle(filled: filled))
    }
}

// MARK: - Pulsing Dot Animation

struct PulsingDot: View {
    let delay: Double
    @State private var opacity: Double = 0.3

    var body: some View {
        Circle()
            .fill(Color.carbonAccent)
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(delay)
                ) {
                    opacity = 1.0
                }
            }
    }
}

struct ThinkingIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            PulsingDot(delay: 0)
            PulsingDot(delay: 0.2)
            PulsingDot(delay: 0.4)
        }
    }
}

// MARK: - Atmospheric Mesh Background

struct CarbonMeshBackground: View {
    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
                .carbonBlack, .carbonBlack, .carbonBlack,
                .carbonBlack, Color(red: 0.08, green: 0.06, blue: 0.04), .carbonBlack,
                .carbonBlack, .carbonBlack, Color(red: 0.06, green: 0.05, blue: 0.03),
            ]
        )
        .ignoresSafeArea()
    }
}

// MARK: - Section Header Style

struct CarbonSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.carbonMono(.caption2, weight: .semibold))
            .foregroundStyle(Color.carbonTextTertiary)
            .kerning(1.2)
    }
}

// MARK: - Context Window Ring

struct ContextRing: View {
    let promptTokens: Int
    let contextWindow: Int

    private var percent: Double {
        guard contextWindow > 0 else { return 0 }
        return Double(promptTokens) / Double(contextWindow) * 100
    }

    private let size: CGFloat = 20
    private let lineWidth: CGFloat = 2.5

    private var arcColor: Color {
        if percent > 90 { return .carbonError }
        if percent > 70 { return .carbonWarning }
        return .carbonAccent
    }

    private var label: String {
        if promptTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(promptTokens) / 1_000_000)
        } else if promptTokens >= 1_000 {
            return String(format: "%.0fK", Double(promptTokens) / 1_000)
        }
        return "\(promptTokens)"
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                // Track
                Circle()
                    .stroke(Color.carbonBorder.opacity(0.4), lineWidth: lineWidth)
                // Fill arc
                Circle()
                    .trim(from: 0, to: min(percent / 100, 1.0))
                    .stroke(arcColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: percent)
            }
            .frame(width: size, height: size)

            Text(label)
                .font(.carbonMono(.caption2))
                .foregroundStyle(percent > 70 ? arcColor : Color.carbonTextSecondary)
        }
    }
}
