import XCTest
@testable import DroidMate

final class ScrcpyKeyboardArgsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.droidmate.tests.keyboard.\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.isEmpty
            ? "x" : defaults.dictionaryRepresentation().description)
        defaults = nil
        super.tearDown()
    }

    func testDefaultKeyboardIsSdk() {
        XCTAssertEqual(ScrcpyController.resolvedKeyboardMode(from: defaults), .sdk)
        let args = ScrcpyController.keyboardArgs(from: defaults)
        XCTAssertTrue(args.contains("--keyboard=sdk"))
        // Mac default: ⌘ as MOD
        XCTAssertTrue(args.contains("--shortcut-mod"))
        XCTAssertTrue(args.contains("lalt,lsuper"))
    }

    func testDefaultMouseIsSdk() {
        XCTAssertEqual(ScrcpyController.resolvedMouseMode(from: defaults), .sdk)
        let args = ScrcpyController.mouseArgs(from: defaults)
        XCTAssertEqual(args, ["--mouse=sdk"])
    }

    func testMouseDisabledViewOnly() {
        defaults.set("disabled", forKey: ScrcpyController.mouseModeKey)
        XCTAssertEqual(ScrcpyController.resolvedMouseMode(from: defaults), .disabled)
        XCTAssertEqual(ScrcpyController.mouseArgs(from: defaults), ["--mouse=disabled"])
    }

    func testUhidMode() {
        defaults.set("uhid", forKey: ScrcpyController.keyboardModeKey)
        XCTAssertEqual(ScrcpyController.resolvedKeyboardMode(from: defaults), .uhid)
        let args = ScrcpyController.keyboardArgs(from: defaults)
        XCTAssertTrue(args.contains("--keyboard=uhid"))
    }

    func testCmdAsModCanBeDisabled() {
        defaults.set(false, forKey: ScrcpyController.cmdAsShortcutModKey)
        let args = ScrcpyController.keyboardArgs(from: defaults)
        XCTAssertFalse(args.contains("--shortcut-mod"))
    }

    func testUnknownModeFallsBackToSdk() {
        defaults.set("not-a-mode", forKey: ScrcpyController.keyboardModeKey)
        XCTAssertEqual(ScrcpyController.resolvedKeyboardMode(from: defaults), .sdk)
    }
}
