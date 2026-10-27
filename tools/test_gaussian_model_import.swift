// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import Foundation

/// Exercises the same ZIP form Python's Mac exporter writes, then imports through ScanLibrary.
/// This deliberately avoids a Metal device: validation and imported-view discovery must happen
/// before the iPhone viewer allocates GPU resources.
@main
struct GaussianModelImportTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gaussian-model-import-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let videoImage = root.appendingPathComponent("frame_00001.jpg")
        let uprightVideo = ScanLibrary.playbackFrames(images: [videoImage], records: [], imagesAreUpright: true)
        try expect(uprightVideo.first?.imageOrientation == .up, "已旋正视频图像被再次按重力旋转")
        let legacyCapture = ScanLibrary.playbackFrames(images: [videoImage], records: [])
        try expect(legacyCapture.first?.imageOrientation == .right, "旧扫描缺少位姿时的方向兼容行为改变")

        let videoManifest = #"{"metricScale":false,"unit":"arbitrary_photogrammetry_unit_normalized","note":"unknown scale retained"}"#
        let valid = root.appendingPathComponent("mac-export.zip")
        try makeDeflatedZip(at: valid, entries: validEntries(videoManifest: videoManifest))
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let library = ScanLibrary(root: libraryRoot)
        let entry = try await library.importGaussianModelArchive(from: valid)
        try expect(entry.isImportedModel, "模型没有标记为导入模型")
        try expect(entry.usedLiDAR == nil && entry.frameCount == 0, "导入模型伪装成采集数据")
        try expect(!fm.fileExists(atPath: entry.directory.appendingPathComponent(CaptureMetadata.fileName).path), "导入模型写入了采集元数据")
        let workspace = TrainingWorkspace(scan: entry.directory)
        try expect(try Data(contentsOf: workspace.modelDirectory.appendingPathComponent("video-import.json")) == Data(videoManifest.utf8),
                   "非米制视频清单没有原样保留")
        let marker = try expectValue(ImportedGaussianModel.read(in: entry.directory), "缺少导入模型标记")
        try expect(marker.sourceFileName == valid.lastPathComponent && marker.scale == "declared-by-video-import",
                   "导入模型来源或尺度标记错误")
        let initialFrames = GaussianModelViewer.initialFrames(in: workspace)
        try expect(initialFrames.count == 1, "导入模型没有可用的训练视角")
        try expect(initialFrames[0].transform == identityTransform, "导入训练视角在读取时被改变")
        try expect((try await library.entries()).count == 1, "成功导入没有出现在历史记录")

        // The normal Mac package prefers SOG and also carries PLY. Exercise that selection
        // with real lossless WebP texels, without allocating a Metal device.
        var sogEntries = validEntries(videoManifest: videoManifest)
        sogEntries["run-42-3dgs/gaussians.sog"] = try minimalGaussianSOG()
        let sogArchive = root.appendingPathComponent("mac-sog-export.zip")
        try makeDeflatedZip(at: sogArchive, entries: sogEntries)
        let sogLibrary = ScanLibrary(root: root.appendingPathComponent("sog-library"))
        let sogEntry = try await sogLibrary.importGaussianModelArchive(from: sogArchive)
        try expect(TrainingWorkspace(scan: sogEntry.directory).modelURL.pathExtension == "sog", "没有选择 Mac 导出的 SOG")
        try expect(GaussianModelViewer.initialFrames(in: TrainingWorkspace(scan: sogEntry.directory)).count == 1,
                   "SOG 导入模型没有初始视角")
        try expectThrows("空 DEFLATE 有效载荷") { _ = try StoredZip.inflate(Data(), size: 1) }
        try await testShareFormats(workspace: TrainingWorkspace(scan: sogEntry.directory), root: root)

        let fakeMetadata = root.appendingPathComponent("fake-metadata.zip")
        var invalidMetadata = validEntries(videoManifest: videoManifest)
        invalidMetadata["run-42-3dgs/gaussians.json"] = Data("{}".utf8)
        try makeDeflatedZip(at: fakeMetadata, entries: invalidMetadata)
        try await expectThrows("空元数据被接受") { _ = try await library.importGaussianModelArchive(from: fakeMetadata) }
        try expect((try await library.entries()).count == 1, "失败的导入被发布到历史记录")

        let missingPose = root.appendingPathComponent("missing-pose.zip")
        var noPose = validEntries(videoManifest: videoManifest)
        noPose.removeValue(forKey: "run-42-3dgs/\(GaussianExport.posesName)")
        try makeDeflatedZip(at: missingPose, entries: noPose)
        try await expectThrows("缺少训练视角被接受") { _ = try await library.importGaussianModelArchive(from: missingPose) }
        try expect((try await library.entries()).count == 1, "缺少视角的模型被发布")

        let truncated = root.appendingPathComponent("truncated-ply.zip")
        var shortPLY = minimalGaussianPLY()
        shortPLY.removeLast()
        var truncatedEntries = validEntries(videoManifest: videoManifest)
        truncatedEntries["run-42-3dgs/gaussians.ply"] = shortPLY
        try makeDeflatedZip(at: truncated, entries: truncatedEntries)
        try await expectThrows("截断 PLY 被接受") { _ = try await library.importGaussianModelArchive(from: truncated) }
        try expect((try await library.entries()).count == 1, "截断模型被发布")

        let traversal = root.appendingPathComponent("traversal.zip")
        try makeDeflatedZip(at: traversal, entries: [
            "../gaussians.ply": minimalGaussianPLY(), "gaussians.json": validMetadata(),
            GaussianExport.posesName: validTrainingPoses()
        ])
        try expectThrows("路径穿越") {
            _ = try GaussianModelImport.unpackArchive(at: traversal, to: root.appendingPathComponent("traversal"))
        }

        let corrupt = root.appendingPathComponent("corrupt.zip")
        var damaged = try Data(contentsOf: valid)
        damaged.removeLast(min(7, damaged.count))
        try damaged.write(to: corrupt)
        try expectThrows("损坏归档") {
            _ = try GaussianModelImport.unpackArchive(at: corrupt, to: root.appendingPathComponent("corrupt"))
        }
        try expectThrows("取消导入") {
            _ = try GaussianModelImport.unpackArchive(at: valid, to: root.appendingPathComponent("cancelled"), isCancelled: { true })
        }
        print("Gaussian model import tests passed")
    }

    private static let identityTransform: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    /// Exercise real ZIP packaging and importing for each selected format without a GPU.
    private static func testShareFormats(workspace: TrainingWorkspace, root: URL) async throws {
        let fm = FileManager.default
        try expect(workspace.availableModelFormats == [.sog, .ply], "双格式模型没有同时提供 SOG 和 PLY")
        let metadataURL = workspace.modelDirectory.appendingPathComponent(GaussianExport.metadataName)
        var fields = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        fields["coordinateFrame"] = GaussianExport.normalizedVideoExportFrame
        fields["futureMetadata"] = ["keep": "未知字段仍保留"]
        fields["ppisp"] = GaussianExport.ppispName
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: metadataURL, options: .atomic)
        let sidecars: [String: Data] = [
            GaussianExport.ppispName: Data(#"{"format":"ppisp","frames":[{"id":7,"exposureEV":0.25}],"note":"raw coefficients unchanged"}"#.utf8),
            GaussianExport.experimentName: Data(#"{"actualIterations":1,"outputs":["gaussians.sog","gaussians.ply"],"note":"original training output record"}"#.utf8),
            GaussianExport.reportName: Data(#"{"iterations":1,"gaussians":1,"elapsedSeconds":0.1}"#.utf8)
        ]
        for (name, bytes) in sidecars { try bytes.write(to: workspace.modelDirectory.appendingPathComponent(name)) }
        let source = try Dictionary(uniqueKeysWithValues:
            fm.contentsOfDirectory(at: workspace.modelDirectory, includingPropertiesForKeys: nil)
                .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        var archives: [TrainingWorkspace.ModelFormat: URL] = [:]
        for format in TrainingWorkspace.ModelFormat.allCases {
            let url = try workspace.makeModelArchive(format: format)
            archives[format] = url
            try expect(url.lastPathComponent.hasSuffix("-3dgs-\(format.rawValue).zip"), "模型 ZIP 文件名未标识选中格式")
            let entries = try StoredZip.entries(Data(contentsOf: url))
            let files = Dictionary(uniqueKeysWithValues: entries.map { (URL(fileURLWithPath: $0.key).lastPathComponent, $0.value) })
            try expect(files[format.fileName] == source[format.fileName], "模型数据在打包时被改变")
            let excluded: TrainingWorkspace.ModelFormat = format == .sog ? .ply : .sog
            try expect(files[excluded.fileName] == nil, "格式选择被忽略，ZIP 仍包含另一种模型")
            for name in [GaussianExport.posesName, GaussianExport.provenanceName,
                         GaussianExport.ppispName, GaussianExport.experimentName, GaussianExport.reportName] {
                try expect(files[name] == source[name], "分享未原样保留来源、位姿、颜色校正或实验记录：\(name)")
            }
            let sharedFields = try JSONSerialization.jsonObject(with: files[GaussianExport.metadataName]!) as! [String: Any]
            try expect(sharedFields["format"] as? String == format.metadataFormat, "模型元数据没有声明选中的格式")
            try expect(sharedFields["coordinateFrame"] as? String == GaussianExport.normalizedVideoExportFrame,
                       "分享把任意尺度改成了米制")
            try expect((sharedFields["futureMetadata"] as? [String: String])?["keep"] == "未知字段仍保留",
                       "分享丢弃了未知元数据字段")
            let importedLibrary = ScanLibrary(root: root.appendingPathComponent("reshare-\(format.rawValue)"))
            let imported = try await importedLibrary.importGaussianModelArchive(from: url)
            let importedWorkspace = TrainingWorkspace(scan: imported.directory)
            try expect(importedWorkspace.modelURL.pathExtension == format.rawValue,
                       "分享包重新导入时未选择指定格式")
            try expect(GaussianModelViewer.initialFrames(in: importedWorkspace).count == 1,
                       "分享包重新导入后丢失相机视角")
            try expect(ImportedGaussianModel.read(in: imported.directory)?.scale == "declared-by-video-import",
                       "分享包重新导入后丢失非米制尺度来源")
            try expect(importedWorkspace.availableModelFormats == [format],
                       "单格式模型导入后错误声明另一格式可用")
            do {
                _ = try importedWorkspace.makeModelArchive(format: excluded)
                throw NSError(domain: "GaussianModelImportTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "单格式导入模型导出了不存在的另一格式"])
            } catch TrainingWorkspace.ShareError.missingFormat {}
            // Whole-scan deletion must clean up every package variant too.
            for archive in importedWorkspace.modelArchiveURLs { try Data("archive".utf8).write(to: archive) }
            try await importedLibrary.delete(imported)
            try expect(!fm.fileExists(atPath: imported.directory.path)
                       && importedWorkspace.modelArchiveURLs.allSatisfy { !fm.fileExists(atPath: $0.path) },
                       "删除扫描未清理两种格式及旧版本归档")
        }
        try expect(archives[.sog] != archives[.ply], "不同格式复用了同一个归档文件")
        for (name, bytes) in source {
            try expect(try Data(contentsOf: workspace.modelDirectory.appendingPathComponent(name)) == bytes,
                       "分享更改了已保存的原始模型文件：\(name)")
        }
        // A stale previous PLY package cannot make a SOG-only model appear exportable as PLY.
        let previousPLY = try Data(contentsOf: archives[.ply]!)
        try fm.removeItem(at: workspace.modelDirectory.appendingPathComponent(GaussianExport.plyName))
        try expect(workspace.availableModelFormats == [.sog], "仅 SOG 模型仍显示可用的 PLY")
        do {
            _ = try workspace.makeModelArchive(format: .ply)
            throw NSError(domain: "GaussianModelImportTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "仅 SOG 模型静默回退或导出了不存在的 PLY"])
        } catch TrainingWorkspace.ShareError.missingFormat {}
        try expect(try Data(contentsOf: archives[.ply]!) == previousPLY, "失败分享覆盖了已有有效的 PLY 归档")
        _ = try workspace.makeModelArchive(format: .sog)
        try source[GaussianExport.plyName]!.write(to: workspace.modelDirectory.appendingPathComponent(GaussianExport.plyName))
        try fm.removeItem(at: workspace.modelDirectory.appendingPathComponent(GaussianSOG.fileName))
        try expect(workspace.availableModelFormats == [.ply], "仅 PLY 模型仍显示可用的 SOG")
        do {
            _ = try workspace.makeModelArchive(format: .sog)
            throw NSError(domain: "GaussianModelImportTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "仅 PLY 模型静默回退或导出了不存在的 SOG"])
        } catch TrainingWorkspace.ShareError.missingFormat {}
        _ = try workspace.makeModelArchive(format: .ply)
        try source[GaussianSOG.fileName]!.write(to: workspace.modelDirectory.appendingPathComponent(GaussianSOG.fileName))
        // Deleting a model also removes both format variants and legacy archives.
        let cleanup = TrainingWorkspace(scan: root.appendingPathComponent("cleanup-scan"))
        try fm.createDirectory(at: cleanup.root, withIntermediateDirectories: true)
        let originalInput = cleanup.scan.appendingPathComponent("original.mov")
        try Data("original input".utf8).write(to: originalInput)
        for archive in cleanup.modelArchiveURLs { try Data("archive".utf8).write(to: archive) }
        try cleanup.removeTraining()
        try expect(cleanup.modelArchiveURLs.allSatisfy { !fm.fileExists(atPath: $0.path) }
                   && fm.fileExists(atPath: originalInput.path), "删除训练结果未清理全部格式归档，或误删原始输入")
        print("Model sharing: SOG/PLY selection, round trips, provenance, unavailable formats and archive cleanup passed")
    }

    private static func validEntries(videoManifest: String) -> [String: Data] {
        [
            "run-42-3dgs/gaussians.ply": minimalGaussianPLY(),
            "run-42-3dgs/gaussians.json": validMetadata(),
            "run-42-3dgs/\(GaussianExport.posesName)": validTrainingPoses(),
            "run-42-3dgs/video-import.json": Data(videoManifest.utf8)
        ]
    }

    private static func validMetadata() -> Data {
        var configuration = GaussianTrainingConfiguration.preset(.quick)
        configuration.shDegree = 0
        configuration.iterations = 1
        let metadata = GaussianExport.Metadata(gaussians: 1, shDegree: 0, mipFilter2D: false,
                                               filterVariancePx2: 0, opacityCompensation: false,
                                               iterations: 1, configuration: configuration, createdAt: Date(),
                                               validationPSNR: nil, viewerNotes: [])
        return try! JSONEncoder.training.encode(metadata)
    }

    private static func minimalGaussianSOG() throws -> Data {
        let texture = try WebPLossless.encode(rgba: [128, 128, 128, 255], width: 1, height: 1)
        let meta = GaussianSOG.Meta(count: 1,
            means: .init(mins: [0, 0, 0], maxs: [0, 0, 0], files: ["means_l.webp", "means_u.webp"]),
            scales: .init(codebook: [Float](repeating: -2, count: 256), files: ["scales.webp"]),
            quats: .init(files: ["quats.webp"]),
            sh0: .init(codebook: [Float](repeating: 0, count: 256), files: ["sh0.webp"]))
        var entries: [(name: String, data: Data)] = [("meta.json", try JSONEncoder().encode(meta))]
        for name in ["means_l.webp", "means_u.webp", "scales.webp", "quats.webp", "sh0.webp"] {
            entries.append((name, texture))
        }
        return StoredZip.archive(entries)
    }

    private static func validTrainingPoses() -> Data {
        let record = FrameRecord(id: 7, timestamp: 0, transform: identityTransform,
                                 intrinsics: CameraIntrinsics(fx: 100, fy: 100, cx: 50, cy: 50, width: 100, height: 100),
                                 exposureDuration: 0, exposureOffsetEV: 0, iso: 0, ambientLux: nil,
                                 estimatedBlurPx: 0, sharpness: 1, sharpnessRatio: 1, blurVerdict: .keep,
                                 imageFile: "frame_00007.jpg", depthFile: nil, confidenceFile: nil,
                                 depthWidth: nil, depthHeight: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try! encoder.encode(record)
        data.append(0x0A)
        return data
    }

    /// One standard INRIA 3DGS row (SH degree 0): 17 little-endian Float32 values.
    private static func minimalGaussianPLY() -> Data {
        let names = GaussianExport.propertyNames(shDegree: 0)
        var data = Data("ply\nformat binary_little_endian 1.0\nelement vertex 1\n".utf8)
        for name in names { data.append(Data("property float \(name)\n".utf8)) }
        data.append(Data("end_header\n".utf8))
        for value: Float in [0, 0, 0, 0, 0, 0, 1, 1, 1, 0, -2, -2, -2, 1, 0, 0, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func makeDeflatedZip(at url: URL, entries: [String: Data]) throws {
        let input = try JSONSerialization.data(withJSONObject: entries.mapValues { $0.base64EncodedString() })
        let script = """
        import base64, json, sys, zipfile
        with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_DEFLATED) as z:
            for name, value in json.loads(sys.stdin.read()).items():
                z.writestr(name, base64.b64decode(value))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, url.path]
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "GaussianModelImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: "GaussianModelImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }

    private static func expectThrows(_ label: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { return }
        throw NSError(domain: "GaussianModelImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(label) was accepted"])
    }

    private static func expectThrows(_ label: String, _ body: () async throws -> Void) async throws {
        do { try await body() }
        catch { return }
        throw NSError(domain: "GaussianModelImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(label) was accepted"])
    }
}
