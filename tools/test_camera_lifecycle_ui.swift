// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
// Add to an iPhone UI test target. Requires an unlocked phone pointed at a lit,
// textured scene. Leaves one newly recorded test scene; never deletes user data.
// System Camera screenshots are evidence for visual review, not a camera-health assertion.
import XCTest

final class CameraLifecycleValidation: XCTestCase {
    @MainActor private func snapshot(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
        print("CAMERA_TREE \(name)\n\(app.debugDescription)")
    }

    @MainActor private func waitReady(_ app: XCUIApplication, _ name: String) {
        let record = app.buttons["betaRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        let result = XCTWaiter.wait(for: [expectation(
            for: NSPredicate(format: "enabled == true"), evaluatedWith: record)], timeout: 25)
        snapshot(app, name)
        XCTAssertEqual(result, .completed, "ARKit did not become ready; inspect camera status and screenshot")
    }

    @MainActor func testEnterBackgroundReenterAndRecord() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 20))
        app.buttons["openCaptureBeta"].tap()
        for round in 1...3 {
            XCTAssertTrue(app.buttons["betaStartCapture"].waitForExistence(timeout: 10))
            app.buttons["betaStartCapture"].tap()
            waitReady(app, "entry-\(round)")
            if round == 1 {
                let quality = app.buttons["betaQuality"]
                let width = quality.frame.width
                XCTAssertTrue(quality.isEnabled)
                quality.tap()
                XCTAssertTrue(quality.label.contains("4K"))
                XCTAssertEqual(quality.frame.width, width, accuracy: 0.5)
                waitReady(app, "4k-ready")
                quality.tap()
                XCTAssertTrue(quality.label.contains("1080p"))
                XCTAssertEqual(quality.frame.width, width, accuracy: 0.5)
                waitReady(app, "1080p-ready")
                let lidar = app.buttons["betaLiDAR"]
                let initial = lidar.value as? String
                lidar.tap()
                waitReady(app, "lidar-toggled")
                lidar.tap()
                XCTAssertEqual(lidar.value as? String, initial)
                waitReady(app, "lidar-restored")
            }
            XCUIDevice.shared.press(.home)
            app.activate()
            waitReady(app, "foreground-\(round)")
            app.buttons["完成"].tap()
            XCTAssertTrue(app.buttons["betaStartCapture"].waitForExistence(timeout: 10))
        }
        app.buttons["betaStartCapture"].tap()
        waitReady(app, "before-recording")
        let record = app.buttons["betaRecord"]
        record.tap()
        XCTAssertEqual(record.label, "停止拍摄")
        let delay = expectation(description: "Collect six seconds of real AR frames")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { delay.fulfill() }
        wait(for: [delay], timeout: 10)
        snapshot(app, "recording")
        record.tap()
        let preview = app.buttons["betaVisualize"]
        XCTAssertTrue(preview.waitForExistence(timeout: 90))
        XCTAssertTrue(preview.isEnabled)
        snapshot(app, "recorded-preview")
        XCUIDevice.shared.press(.home)
        let camera = XCUIApplication(bundleIdentifier: "com.apple.camera")
        camera.activate()
        snapshot(camera, "system-camera-after-capture")
    }

    // Run separately when initialization cannot settle (e.g. a covered lens).
    // This verifies recovery UI; it does not count as successful real capture.
    @MainActor func testStalledInitializationOffersRetry() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.launch()
        app.buttons["openCaptureBeta"].tap()
        app.buttons["betaStartCapture"].tap()
        let retry = app.buttons["betaRestartCamera"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        snapshot(app, "stalled-retry-available")
        retry.tap()
        XCTAssertTrue(app.buttons["betaRecord"].exists)
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        snapshot(app, "retry-remains-available-if-tracking-still-unavailable")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        let quality = app.buttons["betaQuality"]
        let width = quality.frame.width
        quality.tap()
        XCTAssertTrue(quality.label.contains("4K"))
        XCTAssertEqual(quality.frame.width, width, accuracy: 0.5)
        quality.tap()
        XCTAssertTrue(quality.label.contains("1080p"))
        XCTAssertEqual(quality.frame.width, width, accuracy: 0.5)
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["betaStartCapture"].waitForExistence(timeout: 10))
        app.buttons["betaStartCapture"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["betaStartCapture"].waitForExistence(timeout: 10))
        let camera = XCUIApplication(bundleIdentifier: "com.apple.camera")
        camera.activate()
        snapshot(camera, "system-camera-after-stalled-session-exit")
    }
}
