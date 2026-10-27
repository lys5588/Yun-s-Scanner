// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import CoreLocation
import MapKit
import Combine

/// Foreground-only location. A missing/denied fix never prevents video capture.
@MainActor final class BetaLocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: SceneLocation?
    @Published private(set) var message = L10n.text("正在获取拍摄位置…")
    private let manager = CLLocationManager()
    private var active = false
    private var directory: URL?
    private var startedAt: Date?
    private var selected: SceneLocation?
    private var geocoding: MKReverseGeocodingRequest?
    private var addressTask: Task<Void, Never>?
    private var lastGeocode = Date.distantPast
    private var generation = UUID()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }
    func start() {
        active = true
        if let location, abs(location.timestamp.timeIntervalSinceNow) > 15 { self.location = nil }
        if location == nil { message = L10n.text("正在获取拍摄位置…") }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default:
            location = nil
            message = L10n.text("未授权定位，视频仍可拍摄。")
        }
    }
    func stop() {
        active = false
        manager.stopUpdatingLocation()
    }
    func begin(directory: URL) {
        generation = UUID()
        self.directory = directory
        startedAt = Date()
        selected = nil
        if let location, abs(location.timestamp.timeIntervalSinceNow) <= 15 { accept(location) }
        start()
    }
    func finish() {
        // The stored fix was observed at capture time. Address lookup may finish later.
        if let selected { persist(selected); resolveAddress(selected) }
        stop()
        startedAt = nil
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard active else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            message = L10n.text("正在获取拍摄位置…")
            manager.startUpdatingLocation()
        case .denied, .restricted:
            location = nil
            message = L10n.text("未授权定位，视频仍可拍摄。")
            manager.stopUpdatingLocation()
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let fix = locations.last,
              abs(fix.timestamp.timeIntervalSinceNow) <= 15, fix.horizontalAccuracy >= 0 else { return }
        let value = SceneLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                  horizontalAccuracyMeters: fix.horizontalAccuracy, timestamp: fix.timestamp)
        guard value.isValid else { return }
        location = value
        message = String(format: "%.5f, %.5f · ±%.0f m", value.latitude, value.longitude, value.horizontalAccuracyMeters)
        if startedAt != nil { accept(value) }
        if Date().timeIntervalSince(lastGeocode) >= 30 { resolveAddress(value) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if location == nil { message = L10n.text("暂未取得位置，视频仍可拍摄。") }
    }
    private func accept(_ value: SceneLocation) {
        guard let startedAt, value.timestamp >= startedAt.addingTimeInterval(-15) else { return }
        // Keep the most accurate fix from this recording, rather than an arbitrary late fix.
        if selected == nil || value.horizontalAccuracyMeters < selected!.horizontalAccuracyMeters {
            selected = value
            persist(value)
        }
    }
    private func persist(_ value: SceneLocation) {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: directory.appendingPathComponent("scene-location.json"), options: .atomic)
        } catch { message = L10n.text("位置保存失败，视频不受影响。") }
    }
    private func resolveAddress(_ value: SceneLocation) {
        geocoding?.cancel(); addressTask?.cancel()
        lastGeocode = Date()
        let token = generation
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: value.latitude, longitude: value.longitude)) else { return }
        request.preferredLocale = L10n.locale
        geocoding = request
        addressTask = Task { [weak self] in
            guard let items = try? await request.mapItems, !Task.isCancelled,
                  let self, token == self.generation,
                  let address = items.first?.address?.fullAddress else { return }
            if self.location?.timestamp == value.timestamp {
                self.location?.address = address
                self.message = address + String(format: " · ±%.0f m", value.horizontalAccuracyMeters)
            }
            if self.selected?.timestamp == value.timestamp {
                self.selected?.address = address
                if let selected = self.selected { self.persist(selected) }
            }
        }
    }
}
