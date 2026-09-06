import SwiftUI

/// The visual language from the "Broadcast pult a zsebben" UX proposal.
///
/// Three rules drive everything here:
///
/// 1. **Colour carries information, never decoration.** Yellow means an armed
///    control, red means a live microphone, green means a healthy link.
///    Everything else is neutral, so the two colours that matter on a dark
///    stage stay unmistakable.
/// 2. **Hard corners.** Radii stay at or below 4pt; this reads as equipment,
///    not as a consumer app, and keeps hit areas rectangular.
/// 3. **Thumb-sized targets.** Controls an operator has to find without
///    looking are 76pt tall, well above the 44pt minimum.
enum DS {
    // MARK: - Colour

    /// Page background.
    static let bg = dynamic(dark: 0x0B0B0C, light: 0xF5F5F2)
    /// Cards and rows.
    static let surface = dynamic(dark: 0x16171A, light: 0xFFFFFF)
    /// Raised elements inside a surface.
    static let surface2 = dynamic(dark: 0x26282D, light: 0xE7E6E1)
    /// Primary text.
    static let ink = dynamic(dark: 0xF5F5F2, light: 0x0B0B0C)
    /// Secondary text.
    static let ink2 = dynamicAlpha(dark: 0xF5F5F2, darkAlpha: 0.62, light: 0x0B0B0C, lightAlpha: 0.62)
    /// Tertiary text: metadata lines.
    static let ink3 = dynamicAlpha(dark: 0xF5F5F2, darkAlpha: 0.66, light: 0x0B0B0C, lightAlpha: 0.55)
    /// Hairlines.
    static let line = dynamicAlpha(dark: 0xFFFFFF, darkAlpha: 0.12, light: 0x0B0B0C, lightAlpha: 0.14)
    /// Fill behind an inactive but available control.
    static let fill = dynamicAlpha(dark: 0xF5F5F2, darkAlpha: 0.13, light: 0x0B0B0C, lightAlpha: 0.08)
    /// Fill behind an engaged toggle.
    static let fillSoft = dynamicAlpha(dark: 0xF5F5F2, darkAlpha: 0.10, light: 0x0B0B0C, lightAlpha: 0.06)

    /// Armed control. Never used for anything that is merely pretty.
    static let accent = Color(hex: 0xFFD400)
    /// On air. Reserved for a microphone that is actually open.
    static let live = Color(hex: 0xFF3B2F)
    /// Healthy connection.
    static let ok = Color(hex: 0x2BD97C)
    /// Text placed on `accent` or `live`.
    static let onAccent = Color(hex: 0x141414)
    /// The accent used as a *foreground* colour. Yellow on a light background is
    /// unreadable, so daylight mode drops to the darker amber the proposal uses
    /// for its own light-theme links. The yellow itself stays a background.
    static let accentText = dynamic(dark: 0xFFD400, light: 0x8A6D00)

    /// Fallback palette for channels the server did not colour.
    static let channelPalette = [0x5B8CFF, 0x2BD97C, 0xFFD400, 0x4FD6D2, 0xB36BFF, 0xFF8A3D]

    // MARK: - Type
    //
    // The proposal uses Archivo and IBM Plex Mono. Neither ships with iOS and
    // bundling them is a separate decision, so the system faces stand in: SF
    // for display, SF Mono for the machine-readable labels. The distinction the
    // design relies on — proportional for names, monospaced for status and
    // controls — survives intact.

    /// Uppercase machine labels: control captions, status lines, section heads.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Names, headings and prose.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - Metrics

    /// Height of a channel row and of the primary transport controls. Large
    /// enough to hit with a thumb without looking at the screen.
    static let controlHeight: CGFloat = 76
    /// Height of secondary full-width actions.
    static let actionHeight: CGFloat = 56
    /// Square icon buttons in the header.
    static let iconSize: CGFloat = 46
    static let talkWidth: CGFloat = 118
    static let listenWidth: CGFloat = 72
    static let channelBarWidth: CGFloat = 6
    static let radius: CGFloat = 0
    static let hairline: CGFloat = 1
    /// Letter spacing for uppercase mono labels.
    static let monoTracking: CGFloat = 1.2

    // MARK: - Colour plumbing

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }

    private static func dynamicAlpha(
        dark: UInt32,
        darkAlpha: CGFloat,
        light: UInt32,
        lightAlpha: CGFloat
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgb: dark).withAlphaComponent(darkAlpha)
                : UIColor(rgb: light).withAlphaComponent(lightAlpha)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Parses the `colorHex` a channel carries, falling back to the first
    /// palette entry rather than rendering something invisible.
    init(channelHex: String) {
        let cleaned = channelHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(hex: UInt32(cleaned, radix: 16) ?? UInt32(DS.channelPalette[0]))
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Shared building blocks

/// An uppercase monospaced label. The design uses these for every control
/// caption, so they get one definition rather than a dozen inline copies.
struct MonoLabel: View {
    let text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold
    var color: Color = DS.ink

    var body: some View {
        Text(text.uppercased())
            .font(DS.mono(size, weight))
            .tracking(DS.monoTracking)
            .foregroundStyle(color)
    }
}

/// Full-width action. `isPrimary` paints it in the armed colour.
struct BlockButton: View {
    let title: String
    var isPrimary = false
    var isEnabled = true
    var height: CGFloat = DS.actionHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MonoLabel(
                text: title,
                size: 12,
                weight: .bold,
                color: isPrimary ? DS.onAccent : DS.ink
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(isPrimary ? DS.accent : .clear)
            .overlay {
                if !isPrimary {
                    Rectangle().stroke(DS.line, lineWidth: DS.hairline)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}


extension AppTheme {
    /// `nil` hands the decision back to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .auto: nil
        }
    }
}
