// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
// Physical-device regression: requires an unlocked iPhone aimed at a lit textured scene.
// The app must be on its reconstruction home page before activation.
// Current black-camera device fails the readiness assertion; this is not a passing capture test.
import XCTest
final class BetaCameraValidation: XCTestCase {
    @MainActor func snap(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
        print("CAMERA_TREE " + name + "\n" + app.debugDescription)
    }
    @MainActor func testCameraReadiness() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.activate(); XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 15))
        app.buttons["openCaptureBeta"].tap()
        app.buttons["betaStartCapture"].tap()
        let record=app.buttons["betaRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        snap(app,"camera-entered")
        let quality = app.buttons["betaQuality"]
        let initial = quality.frame
        XCTAssertTrue(quality.isEnabled)
        quality.tap()
        XCTAssertTrue(quality.label.contains("4K"))
        XCTAssertEqual(quality.frame.width, initial.width, accuracy: 0.5)
        XCTAssertEqual(quality.frame.minX, initial.minX, accuracy: 0.5)
        snap(app,"camera-4k")
        quality.tap()
        XCTAssertTrue(quality.label.contains("1080p"))
        XCTAssertEqual(quality.frame.width, initial.width, accuracy: 0.5)
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record)
        let result = XCTWaiter.wait(for: [ready], timeout: 25)
        snap(app,"camera-after-wait")
        XCTAssertEqual(result,.completed)
        record.tap()
        XCTAssertEqual(record.label, "停止拍摄")
        snap(app,"camera-recording")
        let delay = expectation(description: "Record real camera frames")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { delay.fulfill() }
        wait(for: [delay], timeout: 10)
        record.tap()
        let preview=app.buttons["betaVisualize"]
        XCTAssertTrue(preview.waitForExistence(timeout: 60))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format:"enabled == true"), evaluatedWith: preview)], timeout:20), .completed)
        snap(app,"camera-captured-preview")
        preview.tap()
        app.buttons["betaSaveZIP"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["betaSaved"].firstMatch.waitForExistence(timeout:60))
        snap(app,"camera-saved")
    }
}
