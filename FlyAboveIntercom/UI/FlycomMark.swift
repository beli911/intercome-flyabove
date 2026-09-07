import SwiftUI

/// The Flycom mark: a level meter of four bars.
///
/// It is the sound itself rather than a picture of a microphone, and it is made
/// only of rectangles — which is what keeps it legible at 18pt in a tab bar and
/// on an embroidered shirt.
///
/// The proportions are the design's 96pt master expressed as fractions, so this
/// view and `scripts/make-app-icon.swift` draw the same shape. The bar heights
/// are deliberately not a tidy ramp: a meter caught mid-syllable reads as
/// audio, a symmetric one reads as a chart.
struct FlycomMark: View {
    var size: CGFloat = 44
    /// Yellow bars on black, the way the app icon and a dark gallery want it.
    /// The default is the brand tile: dark bars on yellow.
    var isInverted = false

    private static let barWidth = 9.0 / 96
    private static let barGap = 7.0 / 96
    private static let bottomInset = 22.0 / 96
    private static let barHeights = [24.0 / 96, 40.0 / 96, 56.0 / 96, 32.0 / 96]

    private var tint: Color { isInverted ? DS.accent : DS.onAccent }
    private var field: Color { isInverted ? Color(hex: 0x0B0B0C) : DS.accent }

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.barGap * size) {
            ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                Rectangle()
                    .fill(tint)
                    .frame(width: Self.barWidth * size, height: height * size)
            }
        }
        .padding(.bottom, Self.bottomInset * size)
        .frame(width: size, height: size, alignment: .bottom)
        .background(field)
        .accessibilityHidden(true)
    }
}

/// The mark next to the name, as it appears on the sign-in screen.
struct FlycomWordmark: View {
    var markSize: CGFloat = 56
    var showsSubtitle = true

    var body: some View {
        HStack(spacing: 14) {
            FlycomMark(size: markSize)

            VStack(alignment: .leading, spacing: 6) {
                Text("FLYCOM")
                    .font(DS.display(26, .heavy))
                    .tracking(0.5)
                    .foregroundStyle(DS.ink)
                if showsSubtitle {
                    MonoLabel(text: "INTERCOM", size: 11, weight: .semibold, color: DS.ink2)
                        .tracking(3.3)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Flycom intercom")
    }
}
