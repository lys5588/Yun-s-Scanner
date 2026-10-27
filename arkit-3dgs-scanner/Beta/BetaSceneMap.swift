// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import SwiftUI
import MapKit

struct BetaSceneMap: View {
    let location: SceneLocation
    let name: String
    @Environment(\.dismiss) private var dismiss
    private var coordinate: CLLocationCoordinate2D { .init(latitude: location.latitude, longitude: location.longitude) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: max(600, location.horizontalAccuracyMeters * 4), longitudinalMeters: max(600, location.horizontalAccuracyMeters * 4)))) {
                    Marker(name, coordinate: coordinate).tint(.orange)
                    MapCircle(center: coordinate, radius: location.horizontalAccuracyMeters).foregroundStyle(.orange.opacity(0.15))
                }.mapControls { MapCompass(); MapScaleView() }.accessibilityIdentifier("betaSceneMap")
                VStack(alignment: .leading, spacing: 8) {
                    Text(location.address ?? L10n.text("已记录坐标，暂无地址。"))
                    Text(String(format: "%.6f, %.6f · WGS84", location.latitude, location.longitude)).font(.caption.monospaced())
                    Text(L10n.text("定位精度约 \(Int(location.horizontalAccuracyMeters.rounded())) 米"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(location.timestamp.formatted(date: .numeric, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.navigationTitle(L10n.text("拍摄位置")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
        }
    }
}
