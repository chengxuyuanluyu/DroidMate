import XCTest
@testable import DroidMate

final class AdbAppManagerTests: XCTestCase {

    func testAppInfoIdentityIsPackage() {
        let a = AdbAppManager.AppInfo(package: "com.example.app", label: "App", apkPath: nil)
        XCTAssertEqual(a.id, "com.example.app")
    }

    func testScopeRawValues() {
        XCTAssertEqual(AdbAppManager.Scope.thirdParty.rawValue, "thirdParty")
        XCTAssertEqual(AdbAppManager.Scope.all.rawValue, "all")
    }

    /// Offline / no-device: list returns empty without throwing.
    func testListPackagesWithoutDeviceIsEmpty() {
        let apps = AdbAppManager.shared.listPackages(serial: "no-such-device-serial-xyz")
        XCTAssertTrue(apps.isEmpty)
    }

    func testParseApplicationLabelVariants() {
        XCTAssertEqual(
            AdbAppManager.parseApplicationLabel(from: "    applicationLabel=WeChat\n"),
            "WeChat"
        )
        XCTAssertEqual(
            AdbAppManager.parseApplicationLabel(from: "application-label:'设置'\n"),
            "设置"
        )
        XCTAssertEqual(
            AdbAppManager.parseApplicationLabel(from: "application-label-zh-CN:'微信'\n"),
            "微信"
        )
        XCTAssertNil(AdbAppManager.parseApplicationLabel(from: "nothing useful here"))
    }
}
