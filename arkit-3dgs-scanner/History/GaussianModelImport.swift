// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import Foundation

/// A model received from another device. This is deliberately separate from capture metadata and
/// training state: importing an already reconstructed model must not pretend the phone captured
/// frames, measured LiDAR depth, or completed a local training run.
nonisolated struct ImportedGaussianModel: Codable, Sendable {
    static let fileName = "imported-model.json"

    let version: Int
    let sourceFileName: String
    let importedAt: Date
    let files: [String]
    /// The model remains in the producer's coordinates. `video-import.json`, when supplied, is
    /// copied byte-for-byte so arbitrary photogrammetry units are not relabelled as metres.
    let scale: String

    init(sourceFileName: String, importedAt: Date = Date(), files: [String], hasVideoImport: Bool) {
        self.version = 1
        self.sourceFileName = sourceFileName
        self.importedAt = importedAt
        self.files = files.sorted()
        self.scale = hasVideoImport ? "declared-by-video-import" : "unknown"
    }

    static func read(in directory: URL) -> ImportedGaussianModel? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportedGaussianModel.self, from: data)
    }
}

/// Archive validation and safe unpacking shared by Files import and command-line regression tests.
/// It never trusts an archive path: selected files are written by their known leaf names only.
nonisolated enum GaussianModelImport {
    static let maximumArchiveBytes = 512 * 1_024 * 1_024
    static let maximumUncompressedBytes = 768 * 1_024 * 1_024
    static let maximumEntries = 64

    enum ImportError: LocalizedError {
        case archiveTooLarge, invalidArchive, missingModel, missingMetadata, unsafePath, unsupportedFile, cancelled

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge: return L10n.text("模型壓縮檔過大，無法在這台裝置匯入。")
            case .invalidArchive: return L10n.text("模型壓縮檔損毀，無法匯入。")
            case .missingModel: return L10n.text("壓縮檔沒有 gaussians.sog 或 gaussians.ply。")
            case .missingMetadata: return L10n.text("壓縮檔沒有有效的 gaussians.json。")
            case .unsafePath: return L10n.text("壓縮檔含有不安全的檔案路徑。")
            case .unsupportedFile: return L10n.text("壓縮檔含有不支援的模型檔案。")
            case .cancelled: return L10n.text("已取消匯入模型。")
            }
        }
    }

    struct Unpacked: Sendable {
        let files: [String]
        let hasVideoImport: Bool
    }

    private static let acceptedFiles: Set<String> = [
        "gaussians.sog", "gaussians.ply", "gaussians.json", "video-import.json",
        "ppisp.json", "training-report.json", "experiment.json", "training-poses.jsonl", "preview.jpg"
    ]

    /// Validates a ZIP (including CRC/deflate), writes only recognized model files into the
    /// caller-owned staging directory, and lets the app's existing reader validate the model.
    static func unpackArchive(at source: URL, to modelDirectory: URL,
                              isCancelled: () -> Bool = { false }) throws -> Unpacked {
        if isCancelled() { throw ImportError.cancelled }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false, let fileSize = values.fileSize, fileSize >= 0 else { throw ImportError.invalidArchive }
        guard fileSize <= maximumArchiveBytes else { throw ImportError.archiveTooLarge }
        let archive = try Data(contentsOf: source, options: .mappedIfSafe)
        if isCancelled() { throw ImportError.cancelled }
        let entries: [String: Data]
        do {
            entries = try StoredZip.entries(archive, limits: .init(maximumEntries: maximumEntries,
                                                                     maximumUncompressedBytes: maximumUncompressedBytes))
        } catch let error as StoredZip.ZipError {
            switch error {
            case .unsupported: throw ImportError.unsupportedFile
            default: throw ImportError.invalidArchive
            }
        }

        var selected: [String: Data] = [:]
        for (path, data) in entries {
            if isCancelled() { throw ImportError.cancelled }
            let leaf = try safeLeafName(path)
            guard acceptedFiles.contains(leaf) else { continue }
            guard selected[leaf] == nil else { throw ImportError.invalidArchive }
            selected[leaf] = data
        }
        guard selected["gaussians.sog"] != nil || selected["gaussians.ply"] != nil else {
            throw ImportError.missingModel
        }
        guard let metadataData = selected["gaussians.json"],
              let metadata = try? JSONDecoder.training.decode(GaussianExport.Metadata.self, from: metadataData) else {
            throw ImportError.missingMetadata
        }
        guard metadata.gaussians > 0, metadata.gaussians <= GaussianModelViewer.maxGaussians,
              (0...3).contains(metadata.shDegree) else { throw ImportError.invalidArchive }
        // An imported model needs a real view for the on-device viewer.  Keep that view inside
        // `model/`: it is training/export provenance, not a synthetic ARKit capture record.
        guard let posesData = selected[GaussianExport.posesName],
              hasUsableTrainingPose(posesData) else {
            throw ImportError.invalidArchive
        }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        for (name, data) in selected {
            if isCancelled() { throw ImportError.cancelled }
            try data.write(to: modelDirectory.appendingPathComponent(name), options: .atomic)
        }
        if isCancelled() { throw ImportError.cancelled }
        guard let model = GaussianExport.modelFile(in: modelDirectory) else {
            throw ImportError.missingModel
        }
        let info: (count: Int, shDegree: Int)
        do {
            if model.pathExtension.lowercased() == "sog" {
                // Bound the nested archive before any general SOG reader can decompress it.
                try validateSOGPayload(model, count: metadata.gaussians, shDegree: metadata.shDegree)
                info = (metadata.gaussians, metadata.shDegree)
            } else {
                info = try GaussianExport.modelInfo(model)
                try validatePLYPayload(model, count: info.count)
            }
        } catch {
            throw ImportError.invalidArchive
        }
        // `modelInfo` rejects non-3DGS headers/SOG metadata.  The sidecar has to describe the
        // exact selected model too; otherwise GaussianModelViewer would fail only after this
        // directory had already appeared in history.
        guard info.count > 0, (0...3).contains(info.shDegree),
              info.count <= GaussianModelViewer.maxGaussians,
              metadata.gaussians == info.count, metadata.shDegree == info.shDegree else {
            throw ImportError.invalidArchive
        }
        return Unpacked(files: Array(selected.keys), hasVideoImport: selected["video-import.json"] != nil)
    }

    private static func hasUsableTrainingPose(_ data: Data) -> Bool {
        let decoder = JSONDecoder.training
        let records = data.split(separator: 0x0A).compactMap { try? decoder.decode(FrameRecord.self, from: Data($0)) }
        return records.contains { TrainingDataset.isValid($0) && $0.blurVerdict == .keep }
    }

    /// The PLY reader checks its header before allocating Metal buffers.  Do the remaining CPU
    /// checks here so a truncated or non-finite row cannot be published as a successful model.
    private static func validatePLYPayload(_ url: URL, count: Int) throws {
        let header = try GaussianExport.readHeader(url)
        guard count > 0, count <= GaussianModelViewer.maxGaussians,
              header.count == count, header.names.count > 0 else { throw ImportError.invalidArchive }
        let rowBytes = header.names.count * MemoryLayout<Float>.size
        let payloadBytes = count.multipliedReportingOverflow(by: rowBytes)
        guard !payloadBytes.overflow else { throw ImportError.invalidArchive }
        let expectedBytes = header.headerBytes.addingReportingOverflow(payloadBytes.partialValue)
        guard !expectedBytes.overflow else { throw ImportError.invalidArchive }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == expectedBytes.partialValue else { throw ImportError.invalidArchive }
        try data.withUnsafeBytes { raw in
            for offset in Swift.stride(from: header.headerBytes, to: data.count, by: MemoryLayout<Float>.size) {
                guard raw.loadUnaligned(fromByteOffset: offset, as: Float.self).isFinite else {
                    throw ImportError.invalidArchive
                }
            }
        }
    }

    /// This prototype accepts only its own SOG writer.  Verify the SOG container and every
    /// texture named by meta.json on CPU; actual texture decoding remains the existing viewer's
    /// responsibility after this bounded structural validation.
    private static func validateSOGPayload(_ url: URL, count: Int, shDegree: Int) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try StoredZip.entries(data, limits: .init(maximumEntries: maximumEntries,
                                                                 maximumUncompressedBytes: maximumUncompressedBytes))
        guard let metaData = entries["meta.json"], let meta = try? JSONDecoder().decode(GaussianSOG.Meta.self, from: metaData),
              meta.version == 2, meta.count == count, (meta.shN?.bands ?? 0) == shDegree,
              meta.means.files.count == 2, meta.quats.files.count == 1,
              meta.scales.files.count == 1, meta.sh0.files.count == 1,
              meta.means.mins.count == 3, meta.means.maxs.count == 3,
              meta.scales.codebook.count == 256, meta.sh0.codebook.count == 256 else {
            throw ImportError.invalidArchive
        }
        let required = meta.means.files + meta.quats.files + meta.scales.files + meta.sh0.files
        guard required.allSatisfy({ !$0.isEmpty && entries[$0]?.isEmpty == false }) else {
            throw ImportError.invalidArchive
        }
        if let sh = meta.shN {
            guard shDegree > 0, sh.files.count == 2, sh.codebook.count == 256,
                  sh.files.allSatisfy({ !$0.isEmpty && entries[$0]?.isEmpty == false }) else {
                throw ImportError.invalidArchive
            }
        } else if shDegree != 0 {
            throw ImportError.invalidArchive
        }
    }

    /// Accept either a flat archive or a producer folder such as `run-3dgs/gaussians.sog`, but
    /// never accept traversal, absolute paths, empty components, or nested extraction targets.
    private static func safeLeafName(_ archivePath: String) throws -> String {
        guard !archivePath.isEmpty, !archivePath.hasPrefix("/"), !archivePath.contains("\\"), !archivePath.contains("\0") else {
            throw ImportError.unsafePath
        }
        let components = archivePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 3,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ImportError.unsafePath
        }
        return String(components[components.count - 1])
    }
}
