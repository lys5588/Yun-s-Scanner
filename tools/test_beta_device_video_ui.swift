// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import XCTest
final class BetaDeviceVideoValidation: XCTestCase {
    @MainActor func snapshot(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor func testExistingVideoToZIP() throws {
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
        let visualize = app.buttons["betaVisualize"]
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if visualize.waitForExistence(timeout: 10) && visualize.isEnabled { break }
            let error = app.descendants(matching: .any)["videoImportMessage"].firstMatch
            if error.exists { snapshot(app, "device-processing-error"); XCTFail(error.label); return }
        }
        snapshot(app, "04-device-processed-preview")
        XCTAssertTrue(visualize.exists && visualize.isEnabled, "Device processing did not load preview within 15 minutes")
        XCTAssertFalse(app.descendants(matching: .any)["betaPreviewLiDAR"].firstMatch.isEnabled)
        visualize.tap()
        XCTAssertTrue(app.buttons["betaSaveZIP"].waitForExistence(timeout: 20))
        snapshot(app, "05-device-visualization")
        app.buttons["betaSaveZIP"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["betaSaved"].firstMatch.waitForExistence(timeout: 90))
        snapshot(app, "06-device-zip-saved")
        XCTAssertTrue(app.buttons["betaShareZIP"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 20))
        app.buttons["openCaptureBeta"].tap()
        let scene = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "RGB")).firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 15))
        scene.tap()
        let reopened = app.buttons["betaVisualize"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: reopened)], timeout: 20), .completed)
        reopened.tap()
        snapshot(app, "07-device-scene-reopened")
    }
}
