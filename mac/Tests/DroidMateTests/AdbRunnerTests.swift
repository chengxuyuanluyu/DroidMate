import XCTest
@testable import DroidMate

@MainActor
final class AdbRunnerTests: XCTestCase {

    func testShellEscapeWrapsInSingleQuotes() {
        XCTAssertEqual(AdbRunner.shellEscape("simple"), "'simple'")
    }

    func testShellEscapeHandlesPathWithSpaces() {
        XCTAssertEqual(AdbRunner.shellEscape("/sdcard/My Files/x"), "'/sdcard/My Files/x'")
    }

    func testShellEscapeEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(AdbRunner.shellEscape("a'b"), "'a'\\''b'")
    }

    func testShellEscapeNeutralisesInjectionAttempt() {
        let escaped = AdbRunner.shellEscape("'; rm -rf /; '")
        XCTAssertTrue(escaped.hasPrefix("'"))
        XCTAssertTrue(escaped.hasSuffix("'"))
        XCTAssertTrue(escaped.contains("'\\''"))
    }
}
