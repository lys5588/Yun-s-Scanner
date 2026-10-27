// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import AVFoundation
import Combine
import RealityKit
import UIKit

nonisolated struct SelectedVideo: Sendable {
    let url: URL
    let draft: URL
    let duration: Double
    let bytes: Int64
    var name: String { url.lastPathComponent }
}

nonisolated enum VideoImportError: LocalizedError {
    case invalidVideo, tooLong, insufficientStorage, tooLarge
    static func display(_ error: Error) -> String {
        if let known = error as? VideoImportError { return known.localizedDescription }
        return L10n.text("無法處理影片：\(error.localizedDescription)")
    }
    var errorDescription: String? {
        switch self {
        case .invalidVideo: return L10n.text("無法讀取影片，請選擇有效的 MOV 或 MP4 檔案。")
        case .tooLong: return L10n.text("請選擇不超過 3 分鐘的影片。")
        case .insufficientStorage: return L10n.text("儲存空間不足，請釋放空間後重試。")
        case .tooLarge: return L10n.text("影片檔案過大，請先裁短至 3 分鐘內並使用 1080p。")
        }
    }
}

/// Owns only its private draft. A scan becomes visible after every camera/cloud artifact succeeds.
@MainActor
final class VideoImportCoordinator: ObservableObject {
    let isBeta: Bool
    init(isBeta: Bool = false) { self.isBeta = isBeta }

    /// Held until RealityKit has acknowledged cancellation and released its input files.
    private(set) static var isPreparing = false
    enum Phase { case idle, copying, ready, extracting, cameras, publishing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var selection: SelectedVideo?
    @Published private(set) var progress = 0.0
    @Published var message: String?
    @Published var preparedScan: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var abandoned = false
    private var previousIdleTimer: Bool?
    private var processingLease: ContinuedProcessingLease?
    private var cleanupTime: UIBackgroundTaskIdentifier = .invalid
    @Published private(set) var backgroundStatus = ""

    func sceneDidEnterBackground() {
        // Inactive scenes are still foreground (system overlays, interruptions).
        // Only an actual background transition needs a continued-processing grant.
        guard isBusy, processingLease?.isGranted != true else { return }
        BackgroundProcessingDiagnostics.record("videoStoppedOnBackground", title: stageTitle)
        beginCleanupTime()
        cancel(forBackground: true)
    }

    private func beginCleanupTime() {
        guard cleanupTime == .invalid else { return }
        cleanupTime = UIApplication.shared.beginBackgroundTask(withName: "video-cleanup") { [weak self] in
            Task { @MainActor in self?.endCleanupTime() }
        }
    }

    private func endCleanupTime() {
        guard cleanupTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(cleanupTime)
        cleanupTime = .invalid
    }

    var isBusy: Bool { [.copying, .extracting, .cameras, .publishing].contains(phase) }
    var isSupported: Bool {
        if #available(iOS 26.0, *) { return VideoPhotogrammetry.isSupported }
        return false
    }
    var unsupportedMessage: String {
        #if targetEnvironment(simulator)
        return L10n.text("此模擬器不支援影片的相機估計。可先選擇和預覽影片；完整重建請在支援 Object Capture 的 iPhone 真機執行。")
        #else
        return L10n.text("此裝置不支援影片重建。需要 iOS 26 或更新版本，以及支援 Object Capture 的 iPhone。")
        #endif
    }
    var stageTitle: String {
        switch phase {
        case .idle, .ready: return L10n.text("選擇已有影片")
        case .copying: return L10n.text("正在匯入影片…")
        case .extracting: return L10n.text("正在抽取影片影格…")
        case .cameras: return L10n.text("正在估計相機與點雲…")
        case .publishing: return L10n.text("正在儲存重建資料…")
        }
    }

    func select(_ source: URL, removeAfterCopy: Bool = false) {
        guard !isBusy else { return }
        cleanupDraft()
        abandoned = false
        message = nil
        backgroundStatus = ""
        phase = .copying
        let id = UUID(); generation = id
        let worker = Task.detached(priority: .userInitiated) {
            defer { if removeAfterCopy { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) } }
            return try await Self.copyAndInspect(source)
        }
        task = Task {
            defer { task = nil; endCleanupTime() }
            do {
                let video = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == id, !Task.isCancelled, !abandoned else {
                    try? FileManager.default.removeItem(at: video.draft)
                    phase = .idle
                    return
                }
                selection = video
                phase = .ready
            } catch {
                phase = .idle
                if !Task.isCancelled { message = VideoImportError.display(error) }
            }
        }
    }

    func prepare(onPublished: @escaping () -> Void) {
        guard !isBusy, let selection else { return }
        guard isSupported else { message = unsupportedMessage; return }
        guard #available(iOS 26.0, *) else { return }
        guard !Self.isPreparing else {
            message = L10n.text("上一個影片處理正在停止，請稍候再試。")
            return
        }
        guard ProcessInfo.processInfo.thermalState != .critical else {
            message = L10n.text("裝置溫度過高，請冷卻後再開始影片重建。")
            return
        }
        guard !TrainingCenter.shared.isBusy else {
            message = L10n.text("另一筆掃描正在訓練，完成或停止後才能開始")
            return
        }
        abandoned = false
        message = nil
        progress = 0
        phase = .extracting
        Self.isPreparing = true
        let id = UUID(); generation = id
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let lease = ContinuedProcessingLease(title: L10n.text("视频位姿与点云重建"), requiresGPU: true,
            onExpiration: { [weak self] in
                self?.beginCleanupTime()
                self?.cancel()
            }, onChange: { [weak self] in
                guard let self else { return }
                // Background scheduling is optional. Its failure must not look like
                // a failure of the foreground photogrammetry operation.
                self.backgroundStatus = self.processingLease?.isGranted == true
                    ? self.processingLease?.status ?? ""
                    : L10n.text("正在前台处理，请保持 App 打开，完成后再切换。")
            })
        processingLease = lease
        lease.begin()
        let worker = Task.detached(priority: .userInitiated) { [self] () throws -> URL in
            let fm = FileManager.default
            let staging = selection.draft.appendingPathComponent("prepared-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: staging) }
            let original = staging.appendingPathComponent(selection.name)
            do { try fm.linkItem(at: selection.url, to: original) }
            catch { try fm.copyItem(at: selection.url, to: original) }
            try Task.checkCancellation()
            var input = original
            if isBeta, original.pathExtension.lowercased() != "mov" {
                // Preserve the exact original, and remux a MOV without changing the codec.
                // Extract from that MOV so its PTS, images and estimated poses stay aligned.
                let mov = staging.appendingPathComponent("capture-video.mov")
                guard let export = AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPresetPassthrough) else {
                    throw VideoImportError.invalidVideo
                }
                try await export.export(to: mov, as: .mov)
                try Task.checkCancellation()
                input = mov
                try JSONSerialization.data(withJSONObject: ["originalFile": original.lastPathComponent,
                    "processingFile": mov.lastPathComponent, "conversion": "passthrough_mov_remux"], options: [.sortedKeys])
                    .write(to: staging.appendingPathComponent("original-video.json"), options: .atomic)
            }
            let limit = min(200, PhotogrammetrySession.limits.maximumNumberOfInputImages)
            _ = try await VideoFrameExtractor.extract(sourceURL: input, scanDirectory: staging, maximumFrames: limit) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, !self.abandoned, self.phase == .extracting else { return }
                    self.progress = fraction
                    self.processingLease?.report(fraction: 0.2 * fraction, subtitle: self.stageTitle)
                }
            }
            try Task.checkCancellation()
            await MainActor.run { [weak self] in self?.phase = .cameras; self?.progress = 0 }
            let prepared = try await VideoPhotogrammetry.prepare(scanDirectory: staging) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, !self.abandoned, self.phase == .cameras else { return }
                    self.progress = fraction
                    self.processingLease?.report(fraction: 0.2 + 0.75 * fraction, subtitle: self.stageTitle)
                }
            }
            try Task.checkCancellation()
            let summary = ScanLibrary.Summary(version: 1, frameCount: prepared.validFrames, pointCount: prepared.points)
            try JSONEncoder().encode(summary).write(to: staging.appendingPathComponent("scan-summary.json"), options: .atomic)
            await MainActor.run { [weak self] in
                self?.phase = .publishing
                self?.processingLease?.report(fraction: 0.95, subtitle: self?.stageTitle ?? "")
            }
            return try await (isBeta ? ScanLibrary.beta : ScanLibrary.shared).publishPreparedVideo(at: staging)
        }
        task = Task {
            var completed = false
            defer {
                processingLease?.finish(success: completed)
                processingLease = nil
                endCleanupTime()
                releaseIdleTimer()
                Self.isPreparing = false
                task = nil
                phase = self.selection == nil ? .idle : .ready
                if abandoned { cleanupDraft() }
            }
            do {
                let scan = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                // Publication is the commit point. A late cancellation must not lose the saved scan.
                completed = true
                onPublished()
                cleanupDraft()
                if !abandoned { preparedScan = scan }
            } catch {
                if !Task.isCancelled { message = VideoImportError.display(error) }
            }
        }
    }

    func cancel(forBackground: Bool = false) {
        guard isBusy else { return }
        task?.cancel()
        releaseIdleTimer()
        message = forBackground
            ? L10n.text("已离开前台，视频处理已停止。请保持 App 打开后重试，原始视频已保留。")
            : L10n.text("已取消處理，原始影片未變更。")
    }

    func leave() {
        abandoned = true
        task?.cancel()
        releaseIdleTimer()
        if !isBusy { cleanupDraft() }
    }

    private func releaseIdleTimer() {
        if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = TrainingCenter.shared.isBusy || previousIdleTimer
            self.previousIdleTimer = nil
        }
    }

    private func cleanupDraft() {
        if let selection { try? FileManager.default.removeItem(at: selection.draft) }
        selection = nil
    }

    nonisolated private static func copyAndInspect(_ source: URL) async throws -> SelectedVideo {
        let scope = source.startAccessingSecurityScopedResource()
        defer { if scope { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("video-imports", isDirectory: true)
        let draft = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: draft, withIntermediateDirectories: true)
        var retained = false
        defer { if !retained { try? fm.removeItem(at: draft) } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw VideoImportError.invalidVideo }
        guard size <= 2_000_000_000 else { throw VideoImportError.tooLarge }
        let free = try draft.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let free, free < Int64(size) + 600_000_000 { throw VideoImportError.insufficientStorage }
        let destination = draft.appendingPathComponent(source.lastPathComponent)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw VideoImportError.insufficientStorage }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        try Task.checkCancellation()
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw VideoImportError.invalidVideo }
        guard duration <= 180 else { throw VideoImportError.tooLong }
        try Task.checkCancellation()
        retained = true
        return SelectedVideo(url: destination, draft: draft, duration: duration, bytes: Int64(size))
    }
}

extension ScanLibrary {
    /// No half-prepared scan is exposed in History, and no capture metadata is fabricated.
    func publishPreparedVideo(at staging: URL) throws -> URL {
        try Task.checkCancellation()
        guard try GaussianExport.normalizedVideoImportProvenance(in: staging) != nil,
              Self.savedRecords(in: staging).0.count >= 8,
              FileManager.default.fileExists(atPath: staging.appendingPathComponent("points.ply").path) else {
            throw LibraryError.invalidDirectory
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("scan_video_" + UUID().uuidString.lowercased(), isDirectory: true)
        try fm.moveItem(at: staging, to: destination)
        return destination
    }
}
