// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Pure Swift regression checks for the iOS 27 RealityKit viewer adapter.
import Foundation
import simd

@main struct GaussianRealityKitViewerTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-5 }

    static func main() {
        do {
            let q = try GaussianRealityKitMath.normalizedQuaternion(SIMD4<Float>(2, 0, 0, 0))
            check(close(q.x, 1) && close(q.y, 0) && close(q.z, 0) && close(q.w, 0), "normalizes scalar-first quaternion without reordering")
        } catch {
            check(false, "normalizes scalar-first quaternion without reordering")
        }

        do {
            _ = try GaussianRealityKitMath.normalizedQuaternion(SIMD4<Float>(0, 0, 0, 0))
            check(false, "rejects zero quaternion")
        } catch { print("PASS: rejects zero quaternion") }
        do {
            try GaussianRealityKitMath.requireFinite(.nan, field: "test")
            check(false, "rejects non-finite values")
        } catch { print("PASS: rejects non-finite values") }

        let identityView = GaussianRealityKitMath.cameraTransform(worldToCamera: matrix_identity_double4x4)
        check(identityView.columns.0 == SIMD4(1, 0, 0, 0)
              && identityView.columns.1 == SIMD4(0, -1, 0, 0)
              && identityView.columns.2 == SIMD4(0, 0, -1, 0),
              "changes OpenCV camera axes to RealityKit without rotating model coordinates")

        // A camera away from the origin with an arbitrary orientation must retain its actual
        // eye and projection. Fixed +Z viewing or bounds centering would fail these checks.
        var cameraToWorld = simd_double4x4(simd_quatd(angle: 0.73, axis: simd_normalize(SIMD3(1, 2, 3))))
        cameraToWorld.columns.3 = SIMD4(4, -2, 8, 1)
        let native = GaussianRealityKitMath.cameraTransform(worldToCamera: simd_inverse(cameraToWorld))
        check(simd_length(native.columns.3 - SIMD4<Float>(4, -2, 8, 1)) < 1e-5,
              "preserves the saved camera position instead of using model bounds")
        let worldPoint = cameraToWorld * SIMD4<Double>(0.5, -0.25, 2, 1)
        let nativePoint = simd_inverse(native) * SIMD4<Float>(worldPoint)
        check(simd_length(nativePoint - SIMD4<Float>(0.5, 0.25, -2, 1)) < 1e-5,
              "preserves saved viewing direction and image projection for a rotated camera")

        check(GaussianRealityKitMath.canAllocateNativeBuffers(additionalBytes: 100, availableBytes: 600, headroomBytes: 450),
              "counts only new native buffers against memory remaining after Metal allocation")
        check(!GaussianRealityKitMath.canAllocateNativeBuffers(additionalBytes: 100, availableBytes: 549, headroomBytes: 450)
              && !GaussianRealityKitMath.canAllocateNativeBuffers(additionalBytes: 0, availableBytes: 449, headroomBytes: 450),
              "keeps required headroom when native buffers would exhaust remaining memory")
    }
}
