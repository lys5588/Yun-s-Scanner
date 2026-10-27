// Simulator-only regression. Requires disposable scan_management_fixture_1/2 copies and scan_ui_validation_real_video.
// Never run against a user library: this test deletes the two fixture copies. Map coordinates are explicitly simulated.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import XCTest
final class BetaManagementUI: XCTestCase {
    @MainActor func snap(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
        print("MANAGEMENT_TREE " + name + "\n" + app.debugDescription)
    }
    @MainActor func openLibrary(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 15))
        app.buttons["openCaptureBeta"].tap(); app.buttons["betaLibrary"].tap()
        XCTAssertTrue(app.buttons["betaLibraryLayout"].waitForExistence(timeout: 10))
    }
    @MainActor func scrollTo(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<7 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor func testManageFixtures() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        openLibrary(app)
        snap(app,"cards")
        let layout = app.buttons["betaLibraryLayout"]
        if layout.label == "切换列表显示" { layout.tap() }
        XCTAssertEqual(layout.label, "切换卡片显示")
        let first = app.buttons["betaScene_scan_management_fixture_1"]
        scrollTo(first,app); first.tap()
        XCTAssertTrue(app.buttons["betaRenameScene"].waitForExistence(timeout:10))
        app.buttons["betaRenameScene"].tap()
        let field = app.textFields["betaSceneNameField"]
        XCTAssertTrue(field.waitForExistence(timeout:5))
        field.tap()
        let value = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        field.typeText("测试场景-A")
        app.buttons["betaRenameSave"].tap()
        XCTAssertTrue(app.buttons["betaRenameScene"].label.contains("测试场景-A"))
        app.buttons["betaOpenMap"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["betaSceneMap"].firstMatch.waitForExistence(timeout:10))
        snap(app,"map-fixture-not-real-gps")
        app.buttons["完成"].firstMatch.tap()
        let remove = app.buttons["betaDeleteScene"]
        scrollTo(remove,app); remove.tap()
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(remove.exists)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(layout.waitForExistence(timeout:10)); snap(app,"list-renamed")
        app.buttons["betaLibrarySelect"].tap()
        app.buttons["betaSelectAll"].tap()
        XCTAssertTrue(app.staticTexts["已选择 3 个场景"].exists)
        let original=app.buttons["betaSelect_scan_ui_validation_real_video"]
        scrollTo(original,app); original.tap()
        XCTAssertTrue(app.staticTexts["已选择 2 个场景"].exists)
        app.buttons["betaBatchSave"].tap()
        XCTAssertTrue(app.buttons["betaBatchSaved"].waitForExistence(timeout:90))
        snap(app,"batch-saved")
        app.buttons["betaLibrarySelect"].tap()
        app.terminate(); openLibrary(app)
        XCTAssertEqual(layout.label,"切换卡片显示")
        XCTAssertTrue(first.label.contains("测试场景-A"))
        let second = app.buttons["betaScene_scan_management_fixture_2"]
        scrollTo(second,app); second.tap()
        XCTAssertTrue(app.buttons["betaDeleteScene"].waitForExistence(timeout:10))
        scrollTo(app.buttons["betaDeleteScene"],app)
        app.buttons["betaDeleteScene"].tap(); app.buttons["删除"].firstMatch.tap()
        XCTAssertTrue(layout.waitForExistence(timeout:10))
        XCTAssertFalse(second.exists)
        app.buttons["betaLibrarySelect"].tap()
        let selectFirst=app.buttons["betaSelect_scan_management_fixture_1"]
        scrollTo(selectFirst,app); selectFirst.tap()
        app.buttons["betaBatchDelete"].tap(); app.buttons["删除"].firstMatch.tap()
        XCTAssertTrue(app.buttons["betaSelect_scan_ui_validation_real_video"].waitForExistence(timeout:10))
        XCTAssertFalse(selectFirst.exists)
        snap(app,"only-original-remains")
    }
}
