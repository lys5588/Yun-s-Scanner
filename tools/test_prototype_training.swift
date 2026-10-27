// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// CPU-only regression for the research prototype's default configuration and reproducibility
// manifest. It deliberately does not construct GaussianMetal or submit GPU work.
import Foundation

@main struct PrototypeTrainingTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "PrototypeTrainingTests", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS: \(message)")
    }

    static func main() async throws {
        let quick = GaussianTrainingConfiguration.preset(.quick)
        try require(quick.longEdge == 960 && quick.iterations == 4_000 && quick.maxGaussians == 300_000,
                    "Quick preset is 960 px, 4,000 iterations and 300,000 Gaussians")

        let original = GaussianTrainingSession.Experiment(
            configuration: quick,
            trainingFrames: [.init(id: 4, imageFile: "frame_00004.jpg"),
                             .init(id: 9, imageFile: "frame_00009.jpg")],
            actualIterations: 4_000,
            elapsedSeconds: 12.5,
            gaussians: 123_456,
            outputs: [GaussianSOG.fileName, GaussianExport.plyName, GaussianExport.experimentName],
            createdAt: Date(timeIntervalSince1970: 0))
        let encoded = try JSONEncoder.training.encode(original)
        let decoded = try JSONDecoder.training.decode(GaussianTrainingSession.Experiment.self, from: encoded)
        try require(decoded.methodName == GaussianExport.prototypeMethodName
                    && decoded.sourceRevision == GaussianExport.prototypeSourceRevision
                    && decoded.configuration == quick
                    && decoded.trainingFrames.map(\.imageFile) == ["frame_00004.jpg", "frame_00009.jpg"]
                    && decoded.actualIterations == 4_000
                    && decoded.gaussians == 123_456
                    && decoded.outputs.contains(GaussianExport.plyName),
                    "experiment manifest round-trips method, revision, configuration, frames and PLY output")

        let properties = GaussianExport.propertyNames(shDegree: quick.shDegree)
        try require(properties.prefix(9) == ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"]
                    && properties.suffix(8) == ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"],
                    "standard PLY property layout is available for the Quick SH degree")

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prototype-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provenance = root.appendingPathComponent(GaussianExport.provenanceName)
        let noImported = try GaussianExport.normalizedVideoImportProvenance(in: root)
        try require(noImported?.source == nil,
                    "native scans without video provenance keep their default ARKit export frame")
        try Data("{\"metricScale\":false,\"unit\":\"arbitrary_photogrammetry_unit_normalized\"}".utf8).write(to: provenance)
        let imported = try GaussianExport.normalizedVideoImportProvenance(in: root)
        try require(imported?.source == provenance
                    && imported?.coordinateFrame.contains("input normalized arbitrary units") == true
                    && imported?.coordinateFrame.contains("rotated 180 deg about X") == true,
                    "non-metric video provenance selects an arbitrary-unit PLY and metadata frame")
        var importedExperiment = original
        importedExperiment.outputs.append(GaussianExport.provenanceName)
        let decodedImported = try JSONDecoder.training.decode(GaussianTrainingSession.Experiment.self,
                                                               from: JSONEncoder.training.encode(importedExperiment))
        try require(decodedImported.outputs.contains(GaussianExport.provenanceName),
                    "experiment manifest records the copied non-metric video provenance")
        try Data("{\"metricScale\":false}".utf8).write(to: provenance)
        do {
            _ = try GaussianExport.normalizedVideoImportProvenance(in: root)
            try require(false, "invalid video provenance must fail")
        } catch GaussianExport.ExportError.invalidVideoImportManifest {
            print("PASS: invalid video provenance fails instead of being mislabeled as ARKit metres")
        }
        try Data("{\"metricScale\":true,\"unit\":\"arbitrary_photogrammetry_unit_normalized\"}".utf8).write(to: provenance)
        do {
            _ = try GaussianExport.normalizedVideoImportProvenance(in: root)
            try require(false, "metric video provenance must not be treated as native ARKit input")
        } catch GaussianExport.ExportError.invalidVideoImportManifest {
            print("PASS: metric video provenance is rejected instead of being mislabeled as native ARKit")
        }
        try await testTrainingDatasetScale(in: root.appendingPathComponent("history", isDirectory: true))
    }

    /// Exercise History's real archive path: it rewrites points.ply while preparing COLMAP,
    /// so validating only GaussianExport's model manifest would miss a false metric label.
    static func testTrainingDatasetScale(in root: URL) async throws {
        let fm = FileManager.default
        let scan = root.appendingPathComponent("scan_video_fixture", isDirectory: true)
        try fm.createDirectory(at: scan.appendingPathComponent("images"), withIntermediateDirectories: true)
        let provenance = Data("{\"metricScale\":false,\"unit\":\"arbitrary_photogrammetry_unit_normalized\"}".utf8)
        let manifest = scan.appendingPathComponent("video-import.json")
        try provenance.write(to: manifest)
        let record = FrameRecord(id: 1, timestamp: 4.5,
            transform: [1,0,0,1.25, 0,1,0,2.5, 0,0,1,4, 0,0,0,1],
            intrinsics: CameraIntrinsics(fx: 100, fy: 101, cx: 50, cy: 40, width: 100, height: 80),
            exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 2, imageFile: "frame_1.jpg")
        try Data("CPU export fixture; image existence is sufficient for this export regression".utf8)
            .write(to: scan.appendingPathComponent("images/frame_1.jpg"))
        try ExportManager.writeRefinedPoses([record], to: scan.appendingPathComponent("poses.jsonl"))
        let points = [CloudPoint(x: 1, y: 2, z: -3, r: 100, g: 120, b: 140)]
        try ExportManager.writePLY(points, to: scan.appendingPathComponent("points.ply"))
        let library = ScanLibrary(root: root)
        guard let entry = try await library.entries().first(where: { $0.id == scan.lastPathComponent }) else {
            throw NSError(domain: "PrototypeTrainingTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Video archive fixture was not listed"])
        }
        let archive = try await library.archive(entry)
        try require(fm.fileExists(atPath: archive.path), "History publishes an ordinary-video training archive")
        let ply = try Data(contentsOf: scan.appendingPathComponent("points.ply"))
        let header = String(decoding: ply.prefix(400), as: UTF8.self).components(separatedBy: "end_header")[0]
        try require(header.contains("normalized arbitrary units") && header.contains("gravity alignment unknown")
                    && !header.contains("ARKit") && !header.contains("meters"),
                    "History archive cannot relabel ordinary-video PLY as gravity-aligned ARKit metres")
        let recovered = try ScanLibrary.readPLY(scan.appendingPathComponent("points.ply"), limit: 10)
        try require(recovered.count == 1 && recovered[0].x == 1 && recovered[0].y == 2 && recovered[0].z == -3,
                    "source-world PLY coordinates are preserved without a metric rescale or export rotation")
        let unchangedManifest = try Data(contentsOf: manifest)
        try require(unchangedManifest == provenance && !fm.fileExists(atPath: scan.appendingPathComponent("capture-meta.json").path),
                    "training archive preserves video provenance and does not manufacture ARKit capture metadata")

        func number(_ data: Data, _ offset: Int) -> Double {
            data.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))) }
        }
        func frameMetadata(_ directory: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("training-coordinate-frame.json"))) as! [String: Any]
        }
        let sparse = scan.appendingPathComponent("sparse/0")
        let cameras = try Data(contentsOf: sparse.appendingPathComponent("images.bin"))
        let cloud = try Data(contentsOf: sparse.appendingPathComponent("points3D.bin"))
        try require(number(cameras, 44) == -1.25 && number(cameras, 52) == 2.5 && number(cameras, 60) == 4
                    && number(cloud, 16) == 1 && number(cloud, 24) == -2 && number(cloud, 32) == 3,
                    "video COLMAP camera translations and cloud use the same rigid export rotation without rescaling")
        let metadata = try frameMetadata(scan)
        try require(metadata["metricScale"] as? Bool == false
                    && metadata["unit"] as? String == "arbitrary_photogrammetry_unit_normalized"
                    && (metadata["inputGravityAlignment"] as? String)?.hasPrefix("unknown") == true
                    && metadata["inputWorldToCOLMAPRowMajor"] as? [Int] == [1,0,0,0, 0,-1,0,0, 0,0,-1,0, 0,0,0,1]
                    && (metadata["worldRotationMeaning"] as? String)?.contains("not a gravity alignment") == true,
                    "COLMAP sidecar explicitly records arbitrary units, unknown gravity and the actual world transform")

        try ExportManager.writeTrainingDataset(records: [record], points: points, to: scan, flipWorldUp: false)
        let identityMetadata = try frameMetadata(scan)
        let unrotatedCloud = try Data(contentsOf: sparse.appendingPathComponent("points3D.bin"))
        try require(identityMetadata["inputWorldToCOLMAPRowMajor"] as? [Int] == [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
                    && number(unrotatedCloud, 24) == 2 && number(unrotatedCloud, 32) == -3,
                    "disabling the optional world rotation updates both COLMAP output and its declared transform")

        let protected = ["points.ply", "sparse/0/images.bin", "sparse/0/points3D.bin", "training-coordinate-frame.json"]
        let previous = try protected.map { try Data(contentsOf: scan.appendingPathComponent($0)) }
        for invalid in ["{}", "{\"metricScale\":true,\"unit\":\"arbitrary_photogrammetry_unit_normalized\"}",
                        "{\"metricScale\":false,\"unit\":\"meters\"}"] {
            try Data(invalid.utf8).write(to: manifest)
            do {
                try ExportManager.writeTrainingDataset(records: [record], points: [], to: scan)
                try require(false, "malformed video scale must prevent dataset replacement")
            } catch ExportManager.TrainingExportError.invalidVideoImportManifest { }
            do {
                try ExportManager.writePLY([], to: scan.appendingPathComponent("points.ply"))
                try require(false, "malformed video scale must prevent direct PLY replacement")
            } catch ExportManager.TrainingExportError.invalidVideoImportManifest { }
        }
        let afterFailure = try protected.map { try Data(contentsOf: scan.appendingPathComponent($0)) }
        try require(previous == afterFailure, "invalid video scale fails before changing any previous PLY or COLMAP output")

        let native = root.appendingPathComponent("scan_native_fixture", isDirectory: true)
        try fm.createDirectory(at: native.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data("CPU fixture".utf8).write(to: native.appendingPathComponent("images/frame_1.jpg"))
        try ExportManager.writeTrainingDataset(records: [record], points: points, to: native)
        let nativePLY = try Data(contentsOf: native.appendingPathComponent("points.ply"))
        let nativeMetadata = try frameMetadata(native)
        let nativeCloud = try Data(contentsOf: native.appendingPathComponent("sparse/0/points3D.bin"))
        try require(String(decoding: nativePLY.prefix(200), as: UTF8.self)
                        .contains("fable ARKit capture (world: ARKit gravity-aligned, Y-up, meters)")
                    && nativeMetadata["metricScale"] as? Bool == true && nativeMetadata["unit"] as? String == "meters"
                    && nativeCloud == cloud,
                    "native ARKit PLY label, metric scale and existing COLMAP rotation remain unchanged")
    }
}
