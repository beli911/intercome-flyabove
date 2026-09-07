import Foundation

/// Translates between the linear gain the transport wants and the decibels an
/// audio operator reads.
///
/// The slider is deliberately not linear in gain: the useful range on an
/// intercom is silence to +6 dB, not LiveKit's full 0...10, and a linear gain
/// slider would put almost the whole travel above unity.
enum ChannelVolume {
    static let minimumDecibels: Double = -40
    static let maximumDecibels: Double = 6
    static let ticks = ["-∞", "-12", "0", "+6"]

    /// 0 is silence; 1 is +6 dB.
    static func gain(forSliderPosition position: Double) -> Double {
        let clamped = min(max(position, 0), 1)
        guard clamped > 0 else { return 0 }
        let decibels = minimumDecibels + clamped * (maximumDecibels - minimumDecibels)
        return pow(10, decibels / 20)
    }

    static func sliderPosition(forGain gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        let decibels = 20 * log10(gain)
        let position = (decibels - minimumDecibels) / (maximumDecibels - minimumDecibels)
        return min(max(position, 0), 1)
    }

    static func label(forGain gain: Double) -> String {
        guard gain > 0 else { return "NÉMÍTVA" }
        let decibels = 20 * log10(gain)
        guard decibels > minimumDecibels else { return "NÉMÍTVA" }
        let rounded = (decibels * 10).rounded() / 10
        return rounded >= 0 ? "+\(formatted(rounded)) dB" : "\(formatted(rounded)) dB"
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
