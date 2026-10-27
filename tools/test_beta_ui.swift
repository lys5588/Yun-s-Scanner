// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import XCTest

final class BetaUIValidation: XCTestCase {
    @MainActor private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func launchBeta() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 20))
        app.buttons["openCaptureBeta"].tap()
        XCTAssertTrue(app.buttons["betaStartCapture"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor func testFlipAndDirectCapture() {
        continueAfterFailure = false
        let app = launchBeta()
        snapshot(app, "beta-home")
        app.buttons["betaStartCapture"].tap()
        XCTAssertTrue(app.buttons["betaRecord"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["continueToCapture"].exists)
        XCTAssertTrue(app.buttons["betaQuality"].exists)
        XCTAssertTrue(app.buttons["betaLiDAR"].exists)
        XCTAssertFalse(app.buttons["betaRecord"].isEnabled, "Simulator must not pretend to record")
        snapshot(app, "beta-camera-simulator")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["returnToReconstruction"].waitForExistence(timeout: 10))
        app.buttons["returnToReconstruction"].tap()
        XCTAssertTrue(app.buttons["startScan"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["betaStartCapture"].isHittable)
        snapshot(app, "reconstruction-home-preserved")
        app.buttons["openCaptureBeta"].tap()
        XCTAssertTrue(app.buttons["betaStartCapture"].waitForExistence(timeout: 10))
        snapshot(app, "beta-home-delivery")
    }
    @MainActor func testImportEntry() {
        continueAfterFailure = false
        let app = launchBeta()
        app.buttons["betaLibrary"].tap()
        XCTAssertTrue(app.buttons["betaImportVideo"].waitForExistence(timeout: 10))
        app.buttons["betaImportVideo"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chooseVideoFromPhotos"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chooseVideoFromFiles"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["videoReconstructionUnavailable"].firstMatch.exists)
        snapshot(app, "beta-video-import")
    }
    @MainActor func testRealVideoPreviewAndZIP() {
        continueAfterFailure = false
        let app = launchBeta()
        // The harness stages a previously processed real video, not simulated sensor data.
        let scene = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "RGB")).firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 15))
        scene.tap()
        XCTAssertTrue(app.buttons["betaVisualize"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.switches["betaPreviewLiDAR"].isEnabled)
        snapshot(app, "beta-real-video-preview")
        app.buttons["betaVisualize"].tap()
        XCTAssertTrue(app.buttons["betaSaveZIP"].waitForExistence(timeout: 10))
        snapshot(app, "beta-visualization")
        app.buttons["betaSaveZIP"].tap()
        let saved = app.descendants(matching: .any)["betaSaved"].firstMatch
        let savedText = app.staticTexts["场景 ZIP 已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 45) || savedText.exists)
        if !app.buttons["betaShareZIP"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["betaShareZIP"].exists)
        snapshot(app, "beta-zip-saved")
    }
}
