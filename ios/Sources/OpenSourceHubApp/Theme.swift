import SwiftUI

enum HubTheme {
    static let accent = Color(red: 0.145, green: 0.420, blue: 0.325) // #256B53 LCSign emerald
    static let accentSoft = Color(red: 0.145, green: 0.420, blue: 0.325).opacity(0.12)
    static let canvasLight = Color(red: 0.965, green: 0.957, blue: 0.933) // #F6F4EE warm cream
    static let canvasDark = Color(red: 0.075, green: 0.082, blue: 0.078)
    static let cardLight = Color.white
    static let cardDark = Color(red: 0.118, green: 0.129, blue: 0.124)

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? canvasDark : canvasLight
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? cardDark : cardLight
    }

    static func heroGradient(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color(red: 0.11, green: 0.22, blue: 0.19), Color(red: 0.13, green: 0.18, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.87, green: 0.95, blue: 0.93), Color(red: 0.93, green: 0.97, blue: 0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func repoIconGradient(for seed: String) -> LinearGradient {
        let palettes: [(Color, Color)] = [
            (Color(red: 0.95, green: 0.57, blue: 0.22), Color(red: 0.85, green: 0.39, blue: 0.12)),
            (Color(red: 0.68, green: 0.69, blue: 0.19), Color(red: 0.51, green: 0.55, blue: 0.14)),
            (Color(red: 0.22, green: 0.72, blue: 0.50), Color(red: 0.13, green: 0.54, blue: 0.37)),
            (Color(red: 0.78, green: 0.42, blue: 0.86), Color(red: 0.59, green: 0.27, blue: 0.72)),
            (Color(red: 0.26, green: 0.58, blue: 0.92), Color(red: 0.16, green: 0.41, blue: 0.78)),
            (Color(red: 0.92, green: 0.38, blue: 0.48), Color(red: 0.76, green: 0.22, blue: 0.34)),
        ]
        var hash = 0
        for scalar in seed.unicodeScalars {
            hash = (hash &* 31) &+ Int(scalar.value)
        }
        let pair = palettes[abs(hash) % palettes.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct HubCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 16
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(HubTheme.card(scheme))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.22 : 0.04), radius: 8, x: 0, y: 2)
    }
}

extension View {
    func hubCard(padding: CGFloat = 16, radius: CGFloat = 20) -> some View {
        modifier(HubCardModifier(padding: padding, radius: radius))
    }
}
