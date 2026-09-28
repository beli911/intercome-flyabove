import XCTest
@testable import FlyAboveIntercom

final class ChannelVolumeTests: XCTestCase {
    func testBottomOfTheTravelIsSilence() {
        XCTAssertEqual(ChannelVolume.gain(forSliderPosition: 0), 0)
        XCTAssertEqual(ChannelVolume.label(forGain: 0), "NÉMÍTVA")
    }

    func testTopOfTheTravelIsPlusSixDecibels() {
        let gain = ChannelVolume.gain(forSliderPosition: 1)
        XCTAssertEqual(20 * log10(gain), 6, accuracy: 0.01)
        XCTAssertEqual(ChannelVolume.label(forGain: gain), "+6 dB")
    }

    func testUnityGainReadsAsZeroDecibels() {
        XCTAssertEqual(ChannelVolume.label(forGain: 1.0), "+0 dB")
    }

    func testRoundTripThroughTheSlider() {
        // Whatever the operator sets has to come back unchanged, or the slider
        // would drift every time the sheet is reopened.
        for position in stride(from: 0.05, through: 1.0, by: 0.05) {
            let gain = ChannelVolume.gain(forSliderPosition: position)
            XCTAssertEqual(
                ChannelVolume.sliderPosition(forGain: gain),
                position,
                accuracy: 0.0001
            )
        }
    }

    func testGainIsMonotonic() {
        var previous = -1.0
        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
            let gain = ChannelVolume.gain(forSliderPosition: position)
            XCTAssertGreaterThan(gain, previous)
            previous = gain
        }
    }

    func testOutOfRangeInputIsClamped() {
        XCTAssertEqual(ChannelVolume.gain(forSliderPosition: -5), 0)
        XCTAssertEqual(
            ChannelVolume.gain(forSliderPosition: 5),
            ChannelVolume.gain(forSliderPosition: 1)
        )
        XCTAssertEqual(ChannelVolume.sliderPosition(forGain: 100), 1)
    }

    func testVeryQuietGainReadsAsMuted() {
        // Below the bottom of the scale there is nothing useful to display.
        XCTAssertEqual(ChannelVolume.label(forGain: 0.0001), "NÉMÍTVA")
    }
}
