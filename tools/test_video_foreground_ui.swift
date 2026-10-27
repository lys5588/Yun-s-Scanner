// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
// Physical-device UI regression; add to an Xcode UI test target.
// Requires Documents/BetaTest-IMG_0568-SDR.mov in the installed app.
// Verifies foreground status and real pose estimation on a device without background GPU access.
// It imports one new test scene and does not delete existing user scenes.
import XCTest
final class VideoForegroundValidation: XCTestCase {
    @MainActor func snapshot(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor func testForegroundVideoCompletes() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 20))
        app.buttons["openCaptureBeta"].tap()
        app.buttons["betaLibrary"].tap()
        app.buttons["betaImportVideo"].tap()
        XCTAssertTrue(app.buttons["chooseVideoFromFiles"].waitForExistence(timeout: 10))
        snapshot(app, "01-device-import-capability")
        XCTAssertFalse(app.descendants(matching: .any)["videoReconstructionUnavailable"].firstMatch.exists, "Device reports photogrammetry unsupported")
        app.buttons["chooseVideoFromFiles"].tap()
        let movie = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "BetaTest-IMG_0568-SDR")).firstMatch
        let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Scanner")).firstMatch
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["我的 iPhone", "我的iPhone", "On My iPhone"])).firstMatch
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["浏览", "瀏覽", "Browse"])).firstMatch
        _ = app.searchFields.firstMatch.waitForExistence(timeout: 10)
        for _ in 0..<8 {
            if movie.waitForExistence(timeout: 2) && movie.isHittable { break }
            if folder.exists && folder.isHittable { folder.tap() }
            else if local.exists && local.isHittable { local.tap() }
            else if browse.exists && browse.isHittable { browse.tap() }
            else { break }
        }
        snapshot(app, "02-device-file-picker")
        print("PICKER_TREE\n" + app.debugDescription)
        XCTAssertTrue(movie.exists && movie.isHittable)
        movie.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "打開", "開啟", "Open"])).firstMatch
        if open.waitForExistence(timeout: 2) && open.isHittable { open.tap() }
        let name = app.staticTexts["selectedVideoName"]
        XCTAssertTrue(name.waitForExistence(timeout: 60))
        XCTAssertTrue(name.label.contains("BetaTest-IMG_0568-SDR"))
        let prepare = app.buttons["prepareVideoReconstruction"]
        XCTAssertTrue(prepare.isEnabled)
        snapshot(app, "03-device-video-selected")
        prepare.tap()
        let mode = app.staticTexts["正在前台处理，请保持 App 打开，完成后再切换。"]
        print("PROCESSING_TREE\n" + app.debugDescription)
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        XCTAssertEqual(mode.label, "正在前台处理，请保持 App 打开，完成后再切换。")
        let visualize = app.buttons["betaVisualize"]
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if visualize.waitForExistence(timeout: 10) && visualize.isEnabled { break }
            let error = app.descendants(matching: .any)["videoImportMessage"].firstMatch
            if error.exists { snapshot(app, "device-processing-error"); XCTFail(error.label); return }
        }
        snapshot(app, "04-device-processed-preview")
        XCTAssertTrue(visualize.exists && visualize.isEnabled, "Device processing did not load preview within 15 minutes")
        XCTAssertFalse(app.descendants(matching: .any)["videoImportMessage"].firstMatch.exists)
    }
}
