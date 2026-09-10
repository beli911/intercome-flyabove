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

    /// 0 is silence; 1 is +6 dB. Piecewise audio taper aligns 1/3 with -12 dB and 2/3 with 0 dB.
    static func gain(forSliderPosition position: Double) -> Double {
        let clamped = min(max(position, 0), 1)
        guard clamped > 0 else { return 0 }
        let decibels: Double
        if clamped <= 1.0 / 3.0 {
            decibels = minimumDecibels + (clamped * 3.0) * (-12.0 - minimumDecibels)
        } else if clamped <= 2.0 / 3.0 {
            decibels = -12.0 + ((clamped - 1.0 / 3.0) * 3.0) * (0.0 - (-12.0))
        } else {
            decibels = 0.0 + ((clamped - 2.0 / 3.0) * 3.0) * (maximumDecibels - 0.0)
        }
        return pow(10, decibels / 20)
    }

    static func sliderPosition(forGain gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        let decibels = 20 * log10(gain)
        guard decibels > minimumDecibels else { return 0 }
        let position: Double
        if decibels <= -12.0 {
            position = ((decibels - minimumDecibels) / (-12.0 - minimumDecibels)) * (1.0 / 3.0)
        } else if decibels <= 0.0 {
            position = 1.0 / 3.0 + ((decibels - (-12.0)) / (0.0 - (-12.0))) * (1.0 / 3.0)
        } else {
            position = 2.0 / 3.0 + ((decibels - 0.0) / (maximumDecibels - 0.0)) * (1.0 / 3.0)
        }
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
