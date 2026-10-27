// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import CoreGraphics
import simd

/// Interactive viewer of a completed model: loads `gaussians.sog` (or an older `gaussians.ply`,
/// + `ppisp.json`) into an
/// inference-only model and renders on its own serial queue with the training rasterizer and
/// ISP, so the saved result looks exactly like the live preview. Memory is checked before
/// loading; requests are coalesced (the latest camera wins).
nonisolated final class GaussianModelViewer: @unchecked Sendable {
    enum ViewerBackend: String, Sendable { case metal, realityKit }

    enum ViewerError: LocalizedError {
        case insufficientMemory(Int)
        var errorDescription: String? {
            switch self {
            case .insufficientMemory(let mb): return L10n.text("記憶體不足，無法開啟 3DGS 模型（約需 \(mb) MB）。請關閉其他 App 後重試。")
            }
        }
    }

    let metadata: GaussianExport.Metadata
    let views: [TrainingFrame]
    let initialDepth: Double
    private let model: GaussianModel
    /// The established renderer remains allocated as a compatibility path and is also the only
    /// way to apply the optional, view-dependent PPISP sidecar.
    private let renderer: GaussianRenderer
    private let ppisp: PPISPModel?
    private let backendDiagnosticURL: URL
    private let queue = DispatchQueue(label: "gaussian-viewer", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: ViewerRequest?
    private var busy = false
    private var selectedBackend: ViewerBackend = .metal
    private var nativePreparationAllowed = false
    private var nativeUnavailabilityReason: String?
    /// Why the native RealityKit route is unavailable. Kept for diagnostics without presenting
    /// a misleading claim that PPISP and the native splat component are visually identical.
    private(set) var realityKitFallbackReason: String?
#if os(iOS) && compiler(>=6.4) && canImport(RealityKit) && !targetEnvironment(simulator)
    /// `Any` prevents an iOS 27-only type from becoming stored ABI in an iOS 17 deployment.
    private var realityKitAssetBacking: Any?

    @available(iOS 27.0, *)
    @MainActor
    var realityKitAsset: GaussianRealityKitAsset? { realityKitAssetBacking as? GaussianRealityKitAsset }
#endif
    static let maxPixels = 900 * 1_200

    /// Largest model the viewer opens (a damaged header must not overflow the estimate).
    static let maxGaussians = 16_000_000

    /// Estimated bytes to open a model of `count` Gaussians.
    static func bytes(count: Int, shDegree: Int) -> Int {
        let rows = (min(max(0, count), maxGaussians) + 1023) / 1024 * 1024
        return rows * (GaussianModel.viewerBytesPerGaussian(shDegree: shDegree) + GaussianRasterizer.bytesPerGaussian
                       + TrainingMemoryPlan.intersectionsPerGaussian * GaussianRasterizer.bytesPerIntersection)
            + GaussianRenderer.bytes(maxPixels: maxPixels)
    }

    /// Extra GPU storage used when a completed model is copied into RealityKit's five splat
    /// buffers. The existing Metal viewer remains available when the device cannot hold both.
    static func realityKitBytes(count: Int, shDegree: Int) -> Int {
        let coefficients = (min(max(0, shDegree), 3) + 1) * (min(max(0, shDegree), 3) + 1)
        return min(max(0, count), maxGaussians) * (3 + 3 + 4 + 1 + 3 * coefficients) * MemoryLayout<Float>.size
    }

    /// Model-only imports carry the producer's refined camera poses inside the model package.
    /// They are view presets, not evidence that this device captured images or measured depth.
    static func initialFrames(in workspace: TrainingWorkspace) -> [TrainingFrame] {
        let records: [FrameRecord]
        if ImportedGaussianModel.read(in: workspace.scan) != nil {
            records = ScanLibrary.readRecords(workspace.modelDirectory.appendingPathComponent(GaussianExport.posesName))
        } else {
            records = ScanLibrary.savedRecords(in: workspace.scan).0
        }
        return records.filter { TrainingDataset.isValid($0) && $0.blurVerdict == .keep }.map {
            TrainingFrame(id: $0.id, imageFile: $0.imageFile, intrinsics: $0.intrinsics, transform: $0.transform,
                          captureEV: nil, isValidation: false)
        }
    }

    init(workspace: TrainingWorkspace, metal: GaussianMetal? = nil) throws {
        backendDiagnosticURL = workspace.modelDirectory.appendingPathComponent("viewer-backend.txt")
        let frames = Self.initialFrames(in: workspace)
        guard !frames.isEmpty else { throw GaussianExport.ExportError.damaged }
        views = frames
        let data = try Data(contentsOf: workspace.modelDirectory.appendingPathComponent(GaussianExport.metadataName))
        metadata = try JSONDecoder.training.decode(GaussianExport.Metadata.self, from: data)
        let header = try GaussianExport.modelInfo(workspace.modelURL)
        guard header.count > 0, header.count <= Self.maxGaussians, (0...3).contains(header.shDegree) else {
            throw GaussianExport.ExportError.damaged
        }
        let needed = Self.bytes(count: header.count, shDegree: header.shDegree)
        if let available = TrainingMemoryPlan.availableBytesIfKnown, needed + TrainingMemoryPlan.headroomBytes > available {
            throw ViewerError.insufficientMemory(needed >> 20)
        }
        let metal = try metal ?? GaussianMetal()
        let rows = (header.count + 1023) / 1024 * 1024
        model = try GaussianModel(metal: metal, capacity: rows, shDegree: header.shDegree, trainable: false)
        try GaussianExport.readModel(workspace.modelURL, into: model)
        let raster = try GaussianRasterizer(metal: metal, capacity: rows,
                                            intersectionCapacity: rows * TrainingMemoryPlan.intersectionsPerGaussian,
                                            maxTiles: 65_536)
        renderer = try GaussianRenderer(metal: metal, raster: raster, maxPixels: Self.maxPixels)
#if os(iOS) && compiler(>=6.4) && canImport(RealityKit) && !targetEnvironment(simulator)
        if #available(iOS 27.0, *) {
            let nativeNeeded = Self.realityKitBytes(count: header.count, shDegree: header.shDegree)
            if let available = TrainingMemoryPlan.availableBytesIfKnown,
               !GaussianRealityKitMath.canAllocateNativeBuffers(additionalBytes: nativeNeeded, availableBytes: available,
                                                                headroomBytes: TrainingMemoryPlan.headroomBytes) {
                nativeUnavailabilityReason = "Not enough available memory to keep the RealityKit splat buffers alongside the compatibility renderer."
            } else {
                nativePreparationAllowed = true
            }
        } else {
            nativeUnavailabilityReason = "RealityKit Gaussian splats require iOS 27 or later."
        }
#else
        nativeUnavailabilityReason = "This build does not include the iOS 27 RealityKit Gaussian splat API."
#endif
        if let ppispData = try? Data(contentsOf: workspace.modelDirectory.appendingPathComponent(GaussianExport.ppispName)),
           let file = try? JSONDecoder().decode(GaussianExport.PPISPFile.self, from: ppispData) {
            ppisp = PPISPModel(file: file)
        } else { ppisp = nil }
        initialDepth = Self.medianDepth(model: model, view: frames.first)
        recordBackend(.metal, reason: nativeUnavailabilityReason ?? "RealityKit preparation is pending.")
    }

    /// Median distance to the Gaussians in front of `view` (the orbit pivot distance).
    static func medianDepth(model: GaussianModel, view: TrainingFrame?) -> Double {
        guard let view, model.count > 0 else { return 1.5 }
        let w2c = GaussianCamera.worldToCamera(arkitRowMajorC2W: view.transform)
        let step = max(1, model.count / 20_000)
        var depths: [Float] = []
        for row in stride(from: 0, to: model.count, by: step) {
            let mean = model.mean(row)
            let m = SIMD4<Double>(Double(mean.x), Double(mean.y), Double(mean.z), 1)
            let z = simd_mul(w2c, m).z
            if z > 0.1 && z < 50 { depths.append(Float(z)) }
        }
        return Double(MRNFStrategy.median(depths) ?? 1.5)
    }

    var gaussians: Int { model.activeCount }

#if os(iOS) && compiler(>=6.4) && canImport(RealityKit) && !targetEnvironment(simulator)
    /// Creates and validates the iOS 27-only resource on the main actor after the background
    /// model load completes. Earlier deployment targets retain only an `Any` backing slot.
    @available(iOS 27.0, *)
    @MainActor
    func prepareRealityKitAsset() {
        guard nativePreparationAllowed, realityKitAsset == nil else { return }
        do {
            let asset = try GaussianRealityKitAsset(model: model)
            try asset.validateAndCacheEntity()
            realityKitAssetBacking = asset
            nativeUnavailabilityReason = nil
            recordBackend(.realityKit, reason: nil)
        }
        catch {
            nativePreparationAllowed = false
            nativeUnavailabilityReason = error.localizedDescription
            recordBackend(.metal, reason: error.localizedDescription)
        }
    }
#endif

    /// Selects the actual saved-model renderer. PPISP has no RealityKit equivalent, so its
    /// camera mode always selects Metal even when a native resource is available.
    @MainActor
    func selectSavedModelBackend(for mode: ISPMode) {
#if os(iOS) && compiler(>=6.4) && canImport(RealityKit) && !targetEnvironment(simulator)
        if mode == .off, #available(iOS 27.0, *), realityKitAsset != nil {
            recordBackend(.realityKit, reason: nil)
            return
        }
#endif
        let reason: String
        if mode == .camera, let nativeReason = nativeUnavailabilityReason,
           nativeReason != "RealityKit preparation is pending." {
            reason = "PPISP correction requires the Metal renderer. Native status: \(nativeReason)"
        } else if mode == .camera {
            reason = "PPISP correction requires the Metal renderer."
        } else {
            reason = nativeUnavailabilityReason ?? "RealityKit is unavailable."
        }
        recordBackend(.metal, reason: reason)
    }

    var activeBackend: ViewerBackend {
        lock.lock(); defer { lock.unlock() }
        return selectedBackend
    }

    private func recordBackend(_ backend: ViewerBackend, reason: String?) {
        lock.lock()
        let changed = selectedBackend != backend || realityKitFallbackReason != reason
        selectedBackend = backend
        realityKitFallbackReason = reason
        lock.unlock()
        guard changed else { return }
        let text = "backend=\(backend.rawValue)\nreason=\(reason ?? "none")\n"
        try? Data(text.utf8).write(to: backendDiagnosticURL, options: .atomic)
    }

    func fitted(width: Int, height: Int) -> (Int, Int) { renderer.fitted(width: width, height: height) }

    /// Renders `request` (orbit views only) asynchronously; `completion` runs on the main queue.
    func render(_ request: ViewerRequest, completion: @escaping @Sendable (RenderedFrame?, ViewerRequest) -> Void) {
        lock.lock()
        guard selectedBackend == .metal else {
            lock.unlock()
            DispatchQueue.main.async { completion(nil, request) }
            return
        }
        pending = request
        let start = !busy
        busy = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pending else { busy = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                let frame = autoreleasepool { () -> RenderedFrame? in
                    guard let orbit = next.orbit else { return nil }
                    let camera = orbit.camera(width: next.width, height: next.height, mipFilter: metadata.mipFilter2D)
                    let isp = next.mode == .off ? nil : ppisp?.uniforms(frame: nil)
                    return try? renderer.render(model: model, camera: camera, shDegree: model.shDegree, isp: isp)
                }
                DispatchQueue.main.async { completion(frame, next) }
            }
        }
    }
}

nonisolated extension PPISPModel {
    /// Rebuilds the ISP from an exported `ppisp.json` (parameters only; no optimiser state).
    init(file: GaussianExport.PPISPFile) {
        self.init(frames: file.frames.count, cameras: max(1, file.cameras.count))
        for (f, frame) in file.frames.enumerated() {
            parameters[exposureOffset + f] = frame.exposureEV
            for k in 0..<min(8, frame.colorLatents.count) { parameters[colorOffset + f * 8 + k] = frame.colorLatents[k] }
        }
        for (c, camera) in file.cameras.enumerated() {
            for ch in 0..<min(3, camera.vignetting.count) {
                for k in 0..<min(5, camera.vignetting[ch].count) { parameters[vignettingOffset + c * 15 + ch * 5 + k] = camera.vignetting[ch][k] }
            }
            for ch in 0..<min(3, camera.responseRaw.count) {
                for k in 0..<min(4, camera.responseRaw[ch].count) { parameters[crfOffset + c * 12 + ch * 4 + k] = camera.responseRaw[ch][k] }
            }
        }
        seedMeanEV = file.seedMeanEV
    }
}
