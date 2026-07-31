import XCTest
@testable import DroidMate

final class ScrcpyRecordingTimerTests: XCTestCase {

    func testFormatZero() {
        XCTAssertEqual(ScrcpyController.formatRecordingDuration(0), "0:00")
    }

    func testFormatMinutesSeconds() {
        XCTAssertEqual(ScrcpyController.formatRecordingDuration(65), "1:05")
        XCTAssertEqual(ScrcpyController.formatRecordingDuration(179), "2:59")
        XCTAssertEqual(ScrcpyController.formatRecordingDuration(180), "3:00")
    }

    func testFormatHours() {
        XCTAssertEqual(ScrcpyController.formatRecordingDuration(3661), "1:01:01")
    }

    func testAdbScreenRecordLimitIsThreeMinutes() {
        XCTAssertEqual(ScrcpyController.adbScreenRecordTimeLimitSeconds, 180)
        XCTAssertEqual(ScrcpyController.adbScreenRecordTimeLimitLabel, "3:00")
    }

    func testFormatNegativeClamped() {
        XCTAssertEqual(ScrcpyController.formatRecordingDuration(-5), "0:00")
    }

    func testQualityPresetParams() {
        XCTAssertEqual(ScrcpyController.QualityPreset.smooth.params?.maxSize, 720)
        XCTAssertEqual(ScrcpyController.QualityPreset.balanced.params?.fps, 60)
        XCTAssertEqual(ScrcpyController.QualityPreset.high.params?.maxSize, 1920)
        XCTAssertNil(ScrcpyController.QualityPreset.custom.params)
    }

    func testWirelessSoftCap() {
        let defaults = UserDefaults(suiteName: "com.droidmate.tests.quality.\(UUID().uuidString)")!
        defaults.set(ScrcpyController.QualityPreset.high.rawValue, forKey: ScrcpyController.qualityPresetKey)
        ScrcpyController.QualityPreset.apply(.high, to: defaults)
        defaults.set(true, forKey: ScrcpyController.wirelessOptimizeKey)

        let usb = ScrcpyController.resolveCaptureParams(serial: "ABCDEF12", defaults: defaults)
        XCTAssertEqual(usb.maxSize, 1920)

        let wifi = ScrcpyController.resolveCaptureParams(serial: "192.168.1.8:5555", defaults: defaults)
        XCTAssertEqual(wifi.maxSize, 1080)
        XCTAssertEqual(wifi.fps, 60)
    }
}
