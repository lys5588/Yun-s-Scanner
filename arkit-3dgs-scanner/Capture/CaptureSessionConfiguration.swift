// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import ARKit

/// 新掃描才能載入世界地圖；續掃沿用 session 的座標系與錨點。
@MainActor
enum CaptureSessionConfiguration {
    static func make(config: CaptureConfig, useLiDAR: Bool = true, initialWorldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let result = ARWorldTrackingConfiguration()
        result.worldAlignment = .gravity
        result.environmentTexturing = .none
        result.isAutoFocusEnabled = true
        result.videoHDRAllowed = false
        result.initialWorldMap = initialWorldMap
        // Video formats are device/OS dependent. Prefer the research baseline's native
        // long-edge-1920, 30 fps stream when it is actually offered; otherwise preserve
        // ARKit's default and record the negotiated dimensions in capture metadata.
        if let preferred = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            Int(max($0.imageResolution.width, $0.imageResolution.height)) == config.preferredVideoLongEdge &&
            $0.framesPerSecond == 30 &&
            $0.captureDevicePosition == .back &&
            $0.captureDeviceType == .builtInWideAngleCamera
        }) {
            result.videoFormat = preferred
        }
        if useLiDAR, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            result.frameSemantics.insert(.sceneDepth)
        }
        // All capture/fusion paths use sceneDepth; do not allocate an unused smoothed-depth stream.
        if useLiDAR, config.useSceneMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            result.sceneReconstruction = .mesh
        }
        return result
    }
}
