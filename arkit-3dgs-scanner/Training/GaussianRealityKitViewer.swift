// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import simd

nonisolated enum GaussianRealityKitMath {
    enum ValidationError: LocalizedError {
        case nonFinite(String)
        case zeroQuaternion

        var errorDescription: String? {
            switch self {
            case .nonFinite(let field): return "The saved Gaussian model contains a non-finite \(field) value."
            case .zeroQuaternion: return "The saved Gaussian model contains a zero-length rotation quaternion."
            }
        }
    }

    static func requireFinite(_ value: Float, field: String) throws {
        guard value.isFinite else { throw ValidationError.nonFinite(field) }
    }

    static func requireFinite(_ value: SIMD3<Float>, field: String) throws {
        try requireFinite(value.x, field: field)
        try requireFinite(value.y, field: field)
        try requireFinite(value.z, field: field)
    }

    /// RealityKit consumes scalar-first quaternions, as does the model's SOG/PLY representation.
    static func normalizedQuaternion(_ value: SIMD4<Float>) throws -> SIMD4<Float> {
        for component in 0..<4 { try requireFinite(value[component], field: "rotation") }
        let length = simd_length(value)
        guard length.isFinite, length > 1e-6 else { throw ValidationError.zeroQuaternion }
        return value / length
    }

    /// Call only after `normalizedQuaternion` has validated the row.
    static func normalizeValidatedQuaternion(_ value: SIMD4<Float>) -> SIMD4<Float> {
        value / simd_length(value)
    }

    /// The shared orbit camera uses OpenCV axes (+Y down, +Z forward). RealityKit's camera
    /// uses +Y up and looks along -Z. Change camera axes once; leave the model's world intact.
    static func cameraTransform(worldToCamera: simd_double4x4) -> simd_float4x4 {
        var cameraToWorld = simd_inverse(worldToCamera)
        cameraToWorld.columns.1 *= -1
        cameraToWorld.columns.2 *= -1
        return simd_float4x4(columns: (SIMD4<Float>(cameraToWorld.columns.0), SIMD4<Float>(cameraToWorld.columns.1),
                                       SIMD4<Float>(cameraToWorld.columns.2), SIMD4<Float>(cameraToWorld.columns.3)))
    }

    /// `availableBytes` is measured after the compatibility renderer has been allocated.
    /// Only the additional native buffers and free headroom must fit into that remainder.
    static func canAllocateNativeBuffers(additionalBytes: Int, availableBytes: Int, headroomBytes: Int) -> Bool {
        availableBytes >= headroomBytes && additionalBytes <= availableBytes - headroomBytes
    }
}

/// RealityKit splat APIs ship with the iOS 27 SDK (Xcode 27 / Swift 6.4). A compiler version is
/// used only to avoid referencing symbols that do not exist in earlier SDK overlays; runtime
/// availability still guards every use on device.
#if os(iOS) && compiler(>=6.4) && canImport(RealityKit) && !targetEnvironment(simulator)
import CoreGraphics
import Metal
import RealityKit
import SwiftUI
import UIKit

@available(iOS 27.0, *)
@MainActor
final class GaussianRealityKitAsset {
    enum AssetError: LocalizedError {
        case empty
        case allocation
        case invalidResource

        var errorDescription: String? {
            switch self {
            case .empty: return "The saved Gaussian model has no active splats."
            case .allocation: return "RealityKit could not allocate the splat buffers."
            case .invalidResource: return "RealityKit rejected the Gaussian splat buffers."
            }
        }
    }

    let id = UUID()
    private let count: Int
    private let degree: GaussianSplatResource.SphericalHarmonicDegree
    private let tupleSH: Int
    private let positionBuffer: LowLevelBuffer
    private let scaleBuffer: LowLevelBuffer
    private let rotationBuffer: LowLevelBuffer
    private let opacityBuffer: LowLevelBuffer
    private let shBuffer: LowLevelBuffer
    private var cachedEntity: Entity?

    init(model: GaussianModel) throws {
        let rows = model.liveRows
        guard !rows.isEmpty else { throw AssetError.empty }
        let shDegree = min(max(model.shDegree, 0), 3)
        guard let degree = GaussianSplatResource.SphericalHarmonicDegree(rawValue: UInt8(shDegree)) else {
            throw AssetError.invalidResource
        }
        count = rows.count
        self.degree = degree
        tupleSH = (shDegree + 1) * (shDegree + 1) - 1

        let layout = model.layout
        let params = model.floats(model.params)
        // Do not turn damaged model values into valid-looking black/identity splats. Validation
        // happens before allocating or publishing a RealityKit resource so Metal can take over.
        for row in rows {
            let mean = Int(layout.means) + row * 3
            let scale = Int(layout.scales) + row * 3
            let quat = Int(layout.quats) + row * 4
            let opacity = Int(layout.opacities) + row
            let dc = Int(layout.sh0) + row * 3
            let position = SIMD3(params[mean], params[mean + 1], params[mean + 2])
            try GaussianRealityKitMath.requireFinite(position, field: "position")
            for channel in 0..<3 {
                try GaussianRealityKitMath.requireFinite(params[scale + channel], field: "scale")
                try GaussianRealityKitMath.requireFinite(params[dc + channel], field: "SH coefficient")
            }
            _ = try GaussianRealityKitMath.normalizedQuaternion(SIMD4(params[quat], params[quat + 1], params[quat + 2], params[quat + 3]))
            try GaussianRealityKitMath.requireFinite(params[opacity], field: "opacity")
            for coefficient in 0..<tupleSH {
                let sh = Int(layout.shN) + row * tupleSH * 3 + coefficient * 3
                for channel in 0..<3 { try GaussianRealityKitMath.requireFinite(params[sh + channel], field: "SH coefficient") }
            }
        }

        func buffer(_ bytes: Int) throws -> LowLevelBuffer {
            try LowLevelBuffer(descriptor: .init(capacity: (bytes + 15) & ~15, sizeMultiple: 16))
        }
        do {
            positionBuffer = try buffer(count * 3 * MemoryLayout<Float>.size)
            scaleBuffer = try buffer(count * 3 * MemoryLayout<Float>.size)
            rotationBuffer = try buffer(count * 4 * MemoryLayout<Float>.size)
            opacityBuffer = try buffer(count * MemoryLayout<Float>.size)
            shBuffer = try buffer(count * (tupleSH + 1) * 3 * MemoryLayout<Float>.size)
        } catch {
            throw AssetError.allocation
        }

        positionBuffer.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Float.self)
            for (outputRow, row) in rows.enumerated() {
                let source = Int(layout.means) + row * 3
                for channel in 0..<3 { out[outputRow * 3 + channel] = params[source + channel] }
            }
        }
        scaleBuffer.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Float.self)
            for (outputRow, row) in rows.enumerated() {
                let source = Int(layout.scales) + row * 3
                for channel in 0..<3 { out[outputRow * 3 + channel] = params[source + channel] }
            }
        }
        rotationBuffer.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Float.self)
            for (outputRow, row) in rows.enumerated() {
                let source = Int(layout.quats) + row * 4
                let rotation = GaussianRealityKitMath.normalizeValidatedQuaternion(SIMD4(params[source], params[source + 1], params[source + 2], params[source + 3]))
                for channel in 0..<4 { out[outputRow * 4 + channel] = rotation[channel] }
            }
        }
        opacityBuffer.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Float.self)
            for (outputRow, row) in rows.enumerated() { out[outputRow] = params[Int(layout.opacities) + row] }
        }
        shBuffer.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Float.self)
            let coefficients = tupleSH + 1
            for (outputRow, row) in rows.enumerated() {
                let destination = outputRow * coefficients * 3
                let dc = Int(layout.sh0) + row * 3
                for channel in 0..<3 { out[destination + channel] = params[dc + channel] }
                for coefficient in 0..<tupleSH {
                    let source = Int(layout.shN) + row * tupleSH * 3 + coefficient * 3
                    let target = destination + (coefficient + 1) * 3
                    // The app stores SH as RGB tuples; RealityKit uses the same tuple order.
                    for channel in 0..<3 { out[target + channel] = params[source + channel] }
                }
            }
        }
    }

    /// Builds once during preparation, then supplies the same validated entity to the scene.
    func validateAndCacheEntity() throws {
        guard cachedEntity == nil else { return }
        func descriptor(_ buffer: LowLevelBuffer, _ format: MTLAttributeFormat, _ stride: Int) -> GaussianSplatResource.BufferDescriptor {
            GaussianSplatResource.BufferDescriptor(buffer: buffer, format: format, stride: stride, offset: 0)
        }
        let resourceBuffers: GaussianSplatResource.BufferResource
        do {
            resourceBuffers = try GaussianSplatResource.BufferResource(
                count: count,
                position: descriptor(positionBuffer, .float3, 3 * 4),
                scale: descriptor(scaleBuffer, .float3, 3 * 4),
                rotation: descriptor(rotationBuffer, .float4, 4 * 4),
                opacity: descriptor(opacityBuffer, .float, 4),
                sphericalHarmonics: (descriptor(shBuffer, .float3, (tupleSH + 1) * 3 * 4), degree)
            )
        } catch {
            throw AssetError.invalidResource
        }
        let resource = GaussianSplatResource(resourceBuffers)
        resource.scaleActivation = .exponential
        resource.opacityActivation = .sigmoid
        resource.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let entity = Entity()
        entity.components.set(GaussianSplatComponent(resource))
        cachedEntity = entity
    }

    var validatedEntity: Entity {
        guard let cachedEntity else { preconditionFailure("RealityKit asset must be validated before display") }
        return cachedEntity
    }
}

@available(iOS 27.0, *)
@MainActor
private final class GaussianRealityKitScene {
    let modelRoot = Entity()
    let camera = PerspectiveCamera()
    private var installedAssetID: UUID?

    /// This happens from RealityView's creation closure, never from a SwiftUI View initializer.
    /// `@State(initialValue:)` evaluates on every value reconstruction even when SwiftUI retains
    /// the old state, so attaching the cached entity there can detach a live scene's splat.
    func installIfNeeded(_ asset: GaussianRealityKitAsset) {
        guard installedAssetID == nil else {
            precondition(installedAssetID == asset.id, "A RealityKit scene cannot switch splat assets in place")
            return
        }
        modelRoot.addChild(asset.validatedEntity)
        installedAssetID = asset.id
    }
}

@available(iOS 27.0, *)
@MainActor
struct GaussianRealityKitViewport: View {
    let asset: GaussianRealityKitAsset
    @Binding var orbit: OrbitCamera?
    let onReset: () -> Void
    @State private var scene = GaussianRealityKitScene()

    init(asset: GaussianRealityKitAsset, orbit: Binding<OrbitCamera?>, onReset: @escaping () -> Void) {
        self.asset = asset
        self._orbit = orbit
        self.onReset = onReset
    }

    var body: some View {
        RealityView { content in
            scene.installIfNeeded(asset)
            content.camera = .virtual
            content.add(scene.modelRoot)
            content.add(scene.camera)
            applyCamera()
        } update: { _ in applyCamera() }
        .background(Color.black)
        .overlay {
            GaussianRealityGestureCapture(
                onOrbit: { translation in
                    orbit?.orbit(dx: Double(translation.width), dy: Double(translation.height))
                },
                onPan: { translation, height in
                    orbit?.pan(dx: Double(translation.width), dy: Double(translation.height), viewHeight: Double(height))
                },
                onZoom: { scale in orbit?.zoom(Double(scale)) },
                onReset: onReset
            )
        }
    }

    private func applyCamera() {
        guard let orbit else { return }
        scene.camera.transform = Transform(matrix: GaussianRealityKitMath.cameraTransform(worldToCamera: orbit.worldToCamera))
        scene.camera.camera.fieldOfViewInDegrees = Float(orbit.fovY * 180 / .pi)
        scene.camera.camera.fieldOfViewOrientation = .vertical
    }
}

@available(iOS 27.0, *)
@MainActor
private struct GaussianRealityGestureCapture: UIViewRepresentable {
    let onOrbit: (CGSize) -> Void
    let onPan: (CGSize, CGFloat) -> Void
    let onZoom: (CGFloat) -> Void
    let onReset: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let orbit = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.orbit(_:)))
        orbit.minimumNumberOfTouches = 1; orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        let zoom = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:)))
        let reset = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.reset))
        reset.numberOfTapsRequired = 2
        for recognizer in [orbit, pan, zoom, reset] as [UIGestureRecognizer] {
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GaussianRealityGestureCapture
        init(parent: GaussianRealityGestureCapture) { self.parent = parent }
        @objc func orbit(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            parent.onOrbit(CGSize(width: translation.x, height: translation.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            parent.onPan(CGSize(width: translation.x, height: translation.y), gesture.view?.bounds.height ?? 1)
            gesture.setTranslation(.zero, in: gesture.view)
        }
        @objc func zoom(_ gesture: UIPinchGestureRecognizer) {
            parent.onZoom(gesture.scale)
            gesture.scale = 1
        }
        @objc func reset() { parent.onReset() }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gesture is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (gesture is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }
    }
}
#endif
