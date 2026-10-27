// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import Foundation

/// Both modes record real ARKit poses; only the LiDAR mode records measured depth.
nonisolated enum CaptureMode: String, CaseIterable, Sendable {
    case camera
    case lidar

    static let preferenceKey = "capture.reconstructionMode"

    static func resolve(_ saved: String, supportsLiDAR: Bool) -> CaptureMode {
        let requested = CaptureMode(rawValue: saved) ?? .lidar
        return requested == .lidar && !supportsLiDAR ? .camera : requested
    }
}
