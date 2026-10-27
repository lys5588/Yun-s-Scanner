// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import Foundation
import simd
import ImageIO
import UniformTypeIdentifiers

/// Scene-level WGS84 location, separate from ARKit's local metric coordinate system.
nonisolated struct SceneLocation: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var latitude: Double
    var longitude: Double
    var horizontalAccuracyMeters: Double
    var timestamp: Date
    var address: String?
    var coordinateSystem = "WGS84"
    var source = "core_location"
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) &&
        (-180...180).contains(longitude) && horizontalAccuracyMeters.isFinite && (0...1_000_000).contains(horizontalAccuracyMeters) &&
        coordinateSystem == "WGS84" && timestamp.timeIntervalSince1970.isFinite
    }
    static func read(in directory: URL) -> Self? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("scene-location.json")),
              let value = try? decoder.decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
}

nonisolated struct SceneInfo: Codable, Sendable {
    var schemaVersion = 1
    var name: String
    static func read(in directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("scene-info.json")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

nonisolated struct ScanEntry: Identifiable, Sendable {
    let id: String
    let directory: URL
    let date: Date
    let frameCount: Int
    let pointCount: Int?
    let usedLiDAR: Bool?
    let cover: URL?
    let archive: URL?
    /// On-device 3DGS state, filled in by the app (`ScanLibrary.entriesWithTraining`).
    var trainingStatus: String? = nil
    var trainingProgress: Double? = nil
    var hasGaussianModel = false
    var canResumeTraining = false
    /// A model copied from Files; it has no local capture or training history.
    var isImportedModel = false
    /// Upright video frames and arbitrary scene units from photogrammetry.
    var isVideoImport = false
    var customName: String? = nil
    var location: SceneLocation? = nil
    var displayName: String { customName ?? date.formatted(date: .numeric, time: .shortened) }
}

nonisolated struct ScanPlaybackFrame: Sendable {
    let image: URL
    let pose: simd_float4x4?
    let timestamp: Double?
    var imagesAreUpright = false
    var imageOrientation: CGImagePropertyOrientation { imagesAreUpright ? .up : ScanImageOrientation.upright(pose: pose) }
}

/// JPEGs use sensor coordinates for training. Infer display rotation from gravity (+Y world)
/// without rotating stored pixels or changing the intrinsics/pose used by reconstruction.
nonisolated enum ScanImageOrientation {
    static func upright(pose: simd_float4x4?) -> CGImagePropertyOrientation {
        guard let pose else { return .right } // legacy portrait capture without a matching pose
        let x = pose.columns.0.y, y = pose.columns.1.y
        guard x.isFinite, y.isFinite, x * x + y * y >= 0.04 else { return .right }
        if abs(x) > abs(y) { return x > 0 ? .left : .right }
        return y >= 0 ? .up : .down
    }
}

nonisolated struct ScanPreview: Sendable {
    var points: [CloudPoint]
    var trajectory: [simd_float4x4]
    var images: [URL]
    var note: String?
    var playbackFrames: [ScanPlaybackFrame] = []
    /// Survives app restarts and stays visible even when a fallback cloud can be shown.
    var processingNotice: String? = nil
}

/// 磁碟是唯一真相來源；不依賴 App 記憶體中的歷史索引，舊版掃描也能列出。
actor ScanLibrary {
    static let shared = ScanLibrary()
    static let beta = ScanLibrary(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("beta-scenes", isDirectory: true))
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scans", isDirectory: true)
    }

    nonisolated struct Summary: Codable {
        let version: Int
        let frameCount: Int
        let pointCount: Int
    }

    nonisolated enum LibraryError: LocalizedError {
        case invalidDirectory, unsupportedPLY, damagedPLY
        var errorDescription: String? {
            switch self {
            case .invalidDirectory: return L10n.text("找不到掃描資料，請重新整理歷史紀錄")
            case .unsupportedPLY: return L10n.text("此點雲格式不支援預覽")
            case .damagedPLY: return L10n.text("點雲檔案不完整")
            }
        }
    }

    func entries() throws -> [ScanEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                              options: [.skipsHiddenFiles])
        var entries: [ScanEntry] = []
        for url in urls where url.lastPathComponent.hasPrefix("scan_") {
            guard (try? validate(url)) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]),
                  values.isDirectory == true else { continue }
            let summary = (try? Data(contentsOf: url.appendingPathComponent("scan-summary.json")))
                .flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
            let meta = CaptureMetadata.data(in: url)
                .flatMap { try? JSONDecoder().decode(SessionMeta.self, from: $0) }
            let imported = ImportedGaussianModel.read(in: url)
            let date = meta.flatMap { ISO8601DateFormatter().date(from: $0.startedAt) }
                ?? imported?.importedAt
                ?? values.creationDate ?? .distantPast
            let photos = imageURLs(in: url)
            let modelPreview = TrainingWorkspace(scan: url).previewURL
            let cover = photos.first ?? (imported != nil && fm.fileExists(atPath: modelPreview.path) ? modelPreview : nil)
            let zip = root.appendingPathComponent(url.lastPathComponent + ".zip")
            entries.append(ScanEntry(id: url.lastPathComponent, directory: url, date: date,
                                     frameCount: max(summary?.frameCount ?? 0, photos.count),
                                     pointCount: summary?.pointCount,
                                     usedLiDAR: meta.map { $0.lidarEnabled ?? $0.lidarAvailable }, cover: cover,
                                     archive: fm.fileExists(atPath: zip.path) ? zip : nil,
                                     isImportedModel: imported != nil,
                                     isVideoImport: fm.fileExists(atPath: url.appendingPathComponent("video-import.json").path),
                                     customName: SceneInfo.read(in: url)?.name,
                                     location: SceneLocation.read(in: url)))
        }
        return entries.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
    }

    /// File enumeration may resolve /var to /private/var on Apple devices.
    /// Validate membership first, then compare canonical locations rather than URL spelling.
    func entry(at directory: URL) throws -> ScanEntry {
        try validate(directory)
        let location = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let entry = try entries().first(where: {
            $0.directory.standardizedFileURL.resolvingSymlinksInPath() == location
        }) else { throw LibraryError.invalidDirectory }
        return entry
    }

    func rename(_ entry: ScanEntry, to name: String) throws {
        try validate(entry.directory)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NSError(domain: "SceneName", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("请输入 1 至 80 个字符的场景名称。")])
        }
        try JSONEncoder().encode(SceneInfo(name: name))
            .write(to: entry.directory.appendingPathComponent("scene-info.json"), options: .atomic)
    }

    /// Imports a previously reconstructed model from Files. The archive is unpacked into a
    /// private sibling staging directory, validated with the same SOG/PLY reader as the viewer,
    /// then moved into the library atomically. No capture or training state is created.
    func importGaussianModelArchive(from source: URL) async throws -> ScanEntry {
        // Files URLs normally require a security scope; ordinary local URLs legitimately return
        // false and remain readable, which also keeps this API usable by migration tools.
        let accessedSecurityScope = source.startAccessingSecurityScopedResource()
        defer { if accessedSecurityScope { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = "scan_imported_" + UUID().uuidString.lowercased()
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let workspace = TrainingWorkspace(scan: staging)
        let unpacked = try GaussianModelImport.unpackArchive(at: source, to: workspace.modelDirectory,
                                                              isCancelled: { Task.isCancelled })
        try Task.checkCancellation()
        guard let model = GaussianExport.modelFile(in: workspace.modelDirectory) else {
            throw GaussianModelImport.ImportError.missingModel
        }
        let info = try GaussianExport.modelInfo(model)
        guard info.count > 0, info.shDegree >= 0 else { throw GaussianModelImport.ImportError.invalidArchive }
        let imported = ImportedGaussianModel(sourceFileName: source.lastPathComponent, files: unpacked.files,
                                             hasVideoImport: unpacked.hasVideoImport)
        try JSONEncoder.training.encode(imported).write(to: staging.appendingPathComponent(ImportedGaussianModel.fileName), options: .atomic)
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        published = true
        guard let entry = try entries().first(where: { $0.id == id }) else { throw LibraryError.invalidDirectory }
        return entry
    }

    /// 掃描停止後即保存可預覽成果，無須等使用者按匯出。
    func saveReview(directory: URL, points: [CloudPoint], records: [FrameRecord]) throws {
        try validate(directory)
        try ExportManager.writePLY(points, to: directory.appendingPathComponent("review.ply"))
        try ExportManager.writeRefinedPoses(records, to: directory.appendingPathComponent("review-poses.jsonl"))
        let summary = Summary(version: 1, frameCount: records.count, pointCount: points.count)
        try JSONEncoder().encode(summary).write(to: directory.appendingPathComponent("scan-summary.json"), options: .atomic)
    }

    func preview(_ entry: ScanEntry) throws -> ScanPreview {
        try validate(entry.directory)
        let fm = FileManager.default
        let directory = entry.directory
        let images = imageURLs(in: directory)
        let (records, hasNewFrames) = Self.savedRecords(in: directory)
        let trajectory = records.filter { $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) }
            .map { RefusionEngine.float4x4(rowMajor: $0.transform) }
        let frames = Self.playbackFrames(images: images, records: records, imagesAreUpright: entry.isVideoImport)
        let processingNotice = Self.captureProcessingNotice(in: directory, records: records)
        var note: String?
        if let data = try? Data(contentsOf: directory.appendingPathComponent("refusion-progress.json")),
           let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let status = report["status"] as? String, status != "completed" {
            note = L10n.text("上次精細融合未完成，目前顯示備援預覽。照片與深度仍保留，可使用「優化訓練資料」重新處理。")
        }
        for name in hasNewFrames ? [] : ["review.ply", "points.ply"] {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                let points = try Self.readPLY(url, limit: 120_000)
                return ScanPreview(points: points, trajectory: trajectory, images: images,
                                   note: points.isEmpty ? L10n.text("這次掃描沒有可預覽的點雲，仍可查看拍攝影像。") : note,
                                   playbackFrames: frames, processingNotice: processingNotice)
            } catch {
                note = L10n.text("既有點雲無法讀取，嘗試從原始深度重建預覽。")
            }
        }
        // 舊版未匯出的掃描通常只有影像、姿態與深度。限制融合預算，避免開歷史時耗盡記憶體。
        let depthRecords = records.filter { $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) && $0.depthFile != nil }
        if !depthRecords.isEmpty {
            let step = max(1, Int(ceil(Double(depthRecords.count) / 180)))
            let usable = stride(from: 0, to: depthRecords.count, by: step).map { depthRecords[$0] }
            var config = CaptureConfig()
            config.refuseMaxCells = 600_000
            config.refuseSampleStride = 2
            let points = RefusionEngine.refuse(records: usable, sessionDir: directory, config: config,
                                               target: 120_000, progress: { _ in })
            return ScanPreview(points: points, trajectory: trajectory, images: images,
                               note: points.isEmpty ? L10n.text("原始深度不足以產生點雲，可切換查看影像。")
                                   : L10n.text("這是由舊版深度資料重建的預覽；原始檔案未變更。"),
                               playbackFrames: frames, processingNotice: processingNotice)
        }
        return ScanPreview(points: [], trajectory: trajectory, images: images,
                           note: note ?? L10n.text("這次掃描沒有儲存點雲或深度資料，可切換查看影像。"),
                           playbackFrames: frames, processingNotice: processingNotice)
    }

    /// A terminated process leaves `processing`; a cooperative cancellation writes
    /// `stopped`. Neither is evidence that the saved fallback preview is a finished cloud.
    nonisolated static func captureProcessingNotice(in directory: URL, records: [FrameRecord]) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("capture-processing.json")),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = report["status"] as? String,
              status == "processing" || status == "stopped" else { return nil }
        if records.contains(where: { $0.depthFile != nil }) {
            return L10n.text("上次点云处理未完成，原始数据已保留。可在更多操作中使用“优化训练数据”重新融合。")
        }
        // The existing History optimizer only refines/fuses real depth. Do not advertise
        // its camera-only photo-selection path as RGB reconstruction of a missing cloud.
        return L10n.text("上次点云处理未完成，原始数据已保留。历史优化不会补算仅相机点云，可使用保存的视频重新导入重建。")
    }

    /// 以檔名配對，不以陣列位置配對；缺圖、缺姿態時仍保留正確的影像／位置關係。
    nonisolated static func playbackFrames(images: [URL], records: [FrameRecord], imagesAreUpright: Bool = false) -> [ScanPlaybackFrame] {
        var byName: [String: FrameRecord] = [:]
        for record in records {
            let name = (record.imageFile as NSString).lastPathComponent
            guard record.imageFile == name || record.imageFile == "images/" + name else { continue }
            byName[name] = record
        }
        return images.map { image in
            let record = byName[image.lastPathComponent]
            let pose = record.flatMap { record -> simd_float4x4? in
                guard record.transform.count == 16, record.transform.allSatisfy(\.isFinite) else { return nil }
                let matrix = RefusionEngine.float4x4(rowMajor: record.transform)
                // Double 可有限但轉 Float 後溢位，不交給 SceneKit。
                guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }) else { return nil }
                return matrix
            }
            return ScanPlaybackFrame(image: image, pose: pose,
                                     timestamp: record.flatMap { $0.timestamp.isFinite ? $0.timestamp : nil },
                                     imagesAreUpright: imagesAreUpright)
        }
    }

    /// Sharing a saved scan must prepare COLMAP too, even if the user never exported live.
    func archive(_ entry: ScanEntry) throws -> URL {
        try validate(entry.directory)
        let directory = entry.directory
        let (records, hasNewFrames) = Self.savedRecords(in: directory)
        guard records.contains(where: { $0.blurVerdict == .keep }) else {
            throw ExportManager.TrainingExportError.noUsableFrames
        }
        var points: [CloudPoint]?
        if !hasNewFrames {
            for name in ["review.ply", "points.ply"] {
                if let saved = try? Self.readPLY(directory.appendingPathComponent(name), limit: 250_000), !saved.isEmpty {
                    points = saved; break
                }
            }
        }
        // Old scans without a saved cloud reuse the existing bounded preview reconstruction.
        if points == nil { points = try preview(entry).points }
        try ExportManager.writeTrainingDataset(records: records, points: points ?? [], to: directory)
        return try ExportManager.makeArchive(of: directory)
    }

    /// Prefer the latest review poses, merging raw frames appended by a resumed scan.
    nonisolated static func savedRecords(in directory: URL) -> ([FrameRecord], Bool) {
        let raw = readRecords(directory.appendingPathComponent("poses.jsonl"))
        let corrected = ["review-poses.jsonl", "poses_refined.jsonl"].lazy
            .map { readRecords(directory.appendingPathComponent($0)) }.first { !$0.isEmpty } ?? []
        var byID: [Int: FrameRecord] = [:]
        for record in raw { byID[record.id] = record }
        for record in corrected { byID[record.id] = record }
        let correctedIDs = Set(corrected.map(\.id))
        let hasNewFrames = !corrected.isEmpty && raw.contains { !correctedIDs.contains($0.id) }
        return (byID.values.sorted { $0.id < $1.id }, hasNewFrames)
    }

    nonisolated struct BatchDeletionError: LocalizedError {
        let deletedCount: Int
        let failedCount: Int
        let reason: String
        var errorDescription: String? {
            L10n.text("已刪除 \(deletedCount) 筆，另有 \(failedCount) 筆未能完整刪除。請重新整理後重試。\n\(reason)")
        }
    }

    /// 使用確認視窗中的快照，避免「全部刪除」意外包含確認之後才新增的掃描。
    /// 先驗證整批路徑，再逐筆刪除；部分失敗時繼續處理其他項目並回報結果。
    func delete(_ entries: [ScanEntry]) throws {
        var seen: Set<URL> = []
        let unique = entries.filter { seen.insert($0.directory.standardizedFileURL).inserted }
        for entry in unique { try validate(entry.directory) }
        var failed = 0
        var firstError: String?
        for entry in unique {
            do { try delete(entry) }
            catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        if let firstError {
            throw BatchDeletionError(deletedCount: unique.count - failed, failedCount: failed, reason: firstError)
        }
    }

    /// 刪除整個掃描目錄（包含照片、Gaussian／USDZ 模型與其他產物）及同名 ZIP。
    /// 失敗時將尚存的資料搬回，讓使用者能從歷史紀錄重試。
    func delete(_ entry: ScanEntry) throws {
        try validate(entry.directory)
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".deleting-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let zip = root.appendingPathComponent(entry.directory.lastPathComponent + ".zip")
        var moved: [(URL, URL)] = []
        do {
            let archives = [zip, root.appendingPathComponent(entry.directory.lastPathComponent + "-metric.zip")]
                + TrainingWorkspace(scan: entry.directory).modelArchiveURLs
            for source in [entry.directory] + archives where fm.fileExists(atPath: source.path) {
                let destination = staging.appendingPathComponent(source.lastPathComponent)
                try fm.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
            try fm.removeItem(at: staging)
        } catch {
            for (source, destination) in moved.reversed() where fm.fileExists(atPath: destination.path) {
                try? fm.moveItem(at: destination, to: source)
            }
            // 回復失敗時保留剩餘資料，不能把它當成暫存檔刪除。
            if let remaining = try? fm.contentsOfDirectory(atPath: staging.path), remaining.isEmpty {
                try? fm.removeItem(at: staging)
            }
            throw error
        }
    }

    func validate(_ directory: URL) throws {
        let expectedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.lastPathComponent.hasPrefix("scan_"),
              resolved.deletingLastPathComponent() == expectedRoot,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw LibraryError.invalidDirectory
        }
    }

    private func imageURLs(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("images"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated static func readRecords(_ url: URL) -> [FrameRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        // crash 中斷留下的最後半行不影響先前完整紀錄。
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(FrameRecord.self, from: Data($0)) }
    }

    /// 讀取 fable 原生的 binary PLY，明確檢查格式與長度，不把損毀資料交给 SceneKit。
    nonisolated static func readPLY(_ url: URL, limit: Int) throws -> [CloudPoint] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let marker = Data("end_header\n".utf8)
        guard let end = data.prefix(65_536).range(of: marker),
              let header = String(data: data[..<end.upperBound], encoding: .ascii) else { throw LibraryError.damagedPLY }
        let lines = header.split(separator: "\n").map(String.init)
        let properties = lines.filter { $0.hasPrefix("property ") }
        guard lines.contains("format binary_little_endian 1.0"),
              properties == ["property float x", "property float y", "property float z",
                             "property uchar red", "property uchar green", "property uchar blue"] else {
            throw LibraryError.unsupportedPLY
        }
        guard let vertex = lines.first(where: { $0.hasPrefix("element vertex ") }),
              let count = Int(vertex.split(separator: " ").last ?? ""), count >= 0,
              count <= (data.count - end.upperBound) / 15 else { throw LibraryError.damagedPLY }
        let step = max(1, Int(ceil(Double(count) / Double(max(1, limit)))))
        var points: [CloudPoint] = []
        points.reserveCapacity(min(count, max(1, limit)))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in stride(from: 0, to: count, by: step) {
                let offset = end.upperBound + index * 15
                func number(_ delta: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + delta, as: UInt32.self)))
                }
                let x = number(0), y = number(4), z = number(8)
                guard x.isFinite, y.isFinite, z.isFinite else { continue }
                points.append(CloudPoint(x: x, y: y, z: z, r: raw[offset + 12], g: raw[offset + 13], b: raw[offset + 14]))
            }
        }
        return points
    }

    /// 傳回縮圖 JPEG；全尺寸相片不常駐 UI 記憶體。
    nonisolated static func imageData(_ url: URL, maxDimension: Int,
                                     orientation: CGImagePropertyOrientation? = nil) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let embedded = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let displayOrientation: CGImagePropertyOrientation
        if embedded != 1 {
            // ImageIO has already applied an explicit EXIF transform above.
            displayOrientation = .up
        } else if let orientation {
            displayOrientation = orientation
        } else {
            // History covers do not already have a playback frame. Read only metadata to
            // resolve that photo's pose; playback passes its orientation and skips this read.
            let directory = url.deletingLastPathComponent().deletingLastPathComponent()
            let records = savedRecords(in: directory).0
            let video = FileManager.default.fileExists(atPath: directory.appendingPathComponent("video-import.json").path)
            displayOrientation = playbackFrames(images: [url], records: records, imagesAreUpright: video).first?.imageOrientation ?? .right
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyOrientation: displayOrientation.rawValue] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
