// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
// CPU tests and optional real-data replay of the production iOS preparation engine.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import Darwin

typealias PG = VideoPhotogrammetry

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "VideoPhotogrammetryTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw NSError(domain: "VideoPhotogrammetryTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "accepted invalid input: \(label)"])
}

private func writeImage(_ url: URL) throws {
    let pixels = Data(repeating: 128, count: 200 * 160 * 3)
    guard let provider = CGDataProvider(data: pixels as CFData),
          let image = CGImage(width: 200, height: 160, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 600,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "VideoPhotogrammetryTest", code: 3)
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "write test JPEG")
}

private func projection(_ p: SIMD3<Float>, _ pose: simd_float4x4, _ k: simd_float3x3) -> SIMD2<Float> {
    let local = pose.inverse * SIMD4(p, 1)
    return SIMD2(k[0][0] * local.x / -local.z + k[2][0], -k[1][1] * local.y / -local.z + k[2][1])
}

private func selfTest() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("video-photogrammetry-\(UUID().uuidString)", isDirectory: true)
    let images = temporary.appendingPathComponent("images", isDirectory: true)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let timeline = (0..<8).map { PG.VideoFrame(imageFile: "frame_\($0).jpg", timestamp: Double($0) / 2 - 2) }
    for frame in timeline { try writeImage(images.appendingPathComponent(frame.imageFile)) }
    try PG.writeJSON(timeline, to: temporary.appendingPathComponent("video-frames.json"))
    _ = try PG.loadTimeline(scanDirectory: temporary)
    var duplicate = timeline
    duplicate[7] = PG.VideoFrame(imageFile: "frame_7.jpg", timestamp: timeline[6].timestamp)
    try rejects("duplicate timestamps") { try PG.validateTimeline(duplicate) }
    duplicate[7] = PG.VideoFrame(imageFile: "frame_0.jpg", timestamp: 4)
    try rejects("duplicate image names") { try PG.validateTimeline(duplicate) }
    var traversal = timeline
    traversal[0] = PG.VideoFrame(imageFile: "../frame_0.jpg", timestamp: -2)
    try PG.writeJSON(traversal, to: temporary.appendingPathComponent("video-frames.json"))
    try rejects("path traversal") { _ = try PG.loadTimeline(scanDirectory: temporary) }
    try PG.writeJSON(timeline, to: temporary.appendingPathComponent("video-frames.json"))
    try FileManager.default.moveItem(at: images.appendingPathComponent("frame_0.jpg"), to: temporary.appendingPathComponent("outside.jpg"))
    try FileManager.default.createSymbolicLink(at: images.appendingPathComponent("frame_0.jpg"), withDestinationURL: temporary.appendingPathComponent("outside.jpg"))
    try rejects("symlink image") { _ = try PG.loadTimeline(scanDirectory: temporary) }
    try FileManager.default.removeItem(at: images.appendingPathComponent("frame_0.jpg"))
    try FileManager.default.moveItem(at: temporary.appendingPathComponent("outside.jpg"), to: images.appendingPathComponent("frame_0.jpg"))

    let k = simd_float3x3(columns: (SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(100, 80, 1)))
    var matrix = simd_float4x4(simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3))))
    matrix.columns.3 = SIMD4(10, -3, 2, 1)
    let points = (0..<80).map { index -> PG.Point in
        let local = SIMD4<Float>(Float(index % 10 - 5) * 0.08, Float(index / 10 - 4) * 0.08, -2, 1)
        let world = matrix * local
        return PG.Point(position: SIMD3(world.x, world.y, world.z), rgb: SIMD3(20, 40, 60))
    }
    let poses = timeline.enumerated().map { index, frame in
        PG.UsablePose(sampleID: index, fileName: frame.imageFile, timestamp: frame.timestamp, matrix: matrix, intrinsics: k, imageSize: SIMD2(200, 160))
    }
    try require(try PG.chooseConvention(poses: poses, points: points).0 == false, "rotated GL camera chooses direct")
    let flippedPoses = poses.map { PG.UsablePose(sampleID: $0.sampleID, fileName: $0.fileName, timestamp: $0.timestamp, matrix: $0.matrix * PG.yzFlip(), intrinsics: $0.intrinsics, imageSize: $0.imageSize) }
    try require(try PG.chooseConvention(poses: flippedPoses, points: points).0, "CV camera chooses local Y/Z flip")
    let opposite = points.map { point -> PG.Point in
        let local = matrix.inverse * SIMD4(point.position, 1)
        let world = matrix * PG.yzFlip() * local
        return PG.Point(position: SIMD3(world.x, world.y, world.z), rgb: point.rgb)
    }
    try rejects("ambiguous camera convention") { _ = try PG.chooseConvention(poses: poses, points: points + opposite) }
    let norm = try PG.normalized(points: points)
    var adjusted = matrix
    adjusted.columns.3 = SIMD4((SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z) - norm.center) * norm.scale, 1)
    let delta = projection(points[0].position, matrix, k) - projection(norm.points[0].position, adjusted, k)
    try require(simd_length(delta) < 0.001, "normalization preserves nontrivial camera projection")
    try rejects("zero point extent") { _ = try PG.normalized(points: [PG.Point(position: .zero, rgb: .zero)]) }
    let raw = timeline.enumerated().map { index, frame in
        PG.RawPose(sampleID: index, imageFile: frame.imageFile, timestamp: frame.timestamp,
                   translation: [10, -3, 2], rotationIXIYIZR: [0, 0, 0, 1],
                   transformColumnMajor: PG.matrixColumnMajor(matrix), intrinsicsColumnMajor: PG.matrixColumnMajor(k), lensDistortion: nil)
    }
    let missingK = raw.map { PG.RawPose(sampleID: $0.sampleID, imageFile: $0.imageFile, timestamp: $0.timestamp, translation: $0.translation, rotationIXIYIZR: $0.rotationIXIYIZR, transformColumnMajor: $0.transformColumnMajor, intrinsicsColumnMajor: nil, lensDistortion: nil) }
    try rejects("missing intrinsics") { _ = try PG.writeReconstruction(scanDirectory: temporary, timeline: timeline, raw: missingK, rawPoints: points) }
    try require(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("poses.jsonl").path), "failure must not publish poses")
    try rejects("cancellation during publication") {
        _ = try PG.writeReconstruction(scanDirectory: temporary, timeline: timeline, raw: raw, rawPoints: points) {
            if FileManager.default.fileExists(atPath: temporary.appendingPathComponent("photogrammetry-poses.json").path) {
                throw CancellationError()
            }
        }
    }
    try require(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("photogrammetry-poses.json").path), "cancel must roll back moved output")
    try require(FileManager.default.fileExists(atPath: images.appendingPathComponent(timeline[0].imageFile).path), "cancel must preserve input image")
    let sourceMetadataURL = temporary.appendingPathComponent("video-source.json")
    try Data("{invalid".utf8).write(to: sourceMetadataURL)
    try rejects("invalid source metadata") { _ = try PG.writeReconstruction(scanDirectory: temporary, timeline: timeline, raw: raw, rawPoints: points) }
    let sourceMetadata: [String: Any] = ["sourceName": "synthetic-cpu-fixture.mov", "extractionMethod": "synthetic CPU test", "signedPTS": [-2.0, 1.5], "nested": ["preserved": true]]
    try JSONSerialization.data(withJSONObject: sourceMetadata, options: [.sortedKeys]).write(to: sourceMetadataURL)
    let result = try PG.writeReconstruction(scanDirectory: temporary, timeline: timeline, raw: raw, rawPoints: points)
    try require(result.validFrames == 8 && result.points == 80, "prepared geometry counts")
    let records = try String(contentsOf: temporary.appendingPathComponent("poses.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(PG.PoseRecord.self, from: Data($0.utf8)) }
    try require(records.map(\.timestamp) == timeline.map(\.timestamp), "signed source timestamps survive publication")
    let manifest = try JSONDecoder().decode(PG.ImportManifest.self, from: Data(contentsOf: temporary.appendingPathComponent("video-import.json")))
    try require(!manifest.metricScale && manifest.unit == "arbitrary_photogrammetry_unit_normalized", "no fabricated metric scale")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.appendingPathComponent("video-import.json"))) as! [String: Any]
    try require((object["videoPreprocessing"] as? NSDictionary)?.isEqual(to: sourceMetadata) == true, "complete source preprocessing metadata travels in model provenance")
    try rejects("overwrite prepared output") { _ = try PG.loadTimeline(scanDirectory: temporary) }
    print("PASS CPU: signed PTS, duplicate/path/symlink rejection, GL/CV cameras, ambiguity, normalization, missing K, cancellation rollback and provenance")
}

private func copyInputs(source: URL, output: URL) throws {
    try require(!FileManager.default.fileExists(atPath: output.path), "output directory must not exist")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source.appendingPathComponent("images", isDirectory: true), to: output.appendingPathComponent("images", isDirectory: true))
    try FileManager.default.copyItem(at: source.appendingPathComponent("video-frames.json"), to: output.appendingPathComponent("video-frames.json"))
}

private func readPLY(_ url: URL) throws -> [PG.Point] {
    let data = try Data(contentsOf: url)
    guard let marker = data.range(of: Data("end_header\n".utf8)) else { throw NSError(domain: "PLY", code: 1) }
    let start = marker.upperBound
    try require((data.count - start) % 15 == 0, "expected binary xyz/RGB PLY")
    return stride(from: start, to: data.count, by: 15).map { offset in
        let position = data.withUnsafeBytes { bytes -> SIMD3<Float> in
            SIMD3((0..<3).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + $0 * 4, as: UInt32.self))) })
        }
        return PG.Point(position: position, rgb: SIMD3(data[offset + 12], data[offset + 13], data[offset + 14]))
    }
}

@main private struct TestVideoPhotogrammetry {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty { try selfTest(); return }
            try require(args.count == 3 && ["--replay", "--prepare", "--cancel"].contains(args[0]), "usage: test_video_photogrammetry [--replay|--prepare|--cancel SOURCE_SCAN NEW_OUTPUT_SCAN]")
            let source = URL(fileURLWithPath: args[1], isDirectory: true)
            let output = URL(fileURLWithPath: args[2], isDirectory: true)
            try copyInputs(source: source, output: output)
            if args[0] == "--cancel" {
                if #available(macOS 26.0, iOS 26.0, *) {
                    let job = Task { try await PG.prepare(scanDirectory: output) { print("cancel-test progress \(Int($0 * 100))%") } }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    job.cancel()
                    do {
                        _ = try await job.value
                        throw NSError(domain: "VideoPhotogrammetryTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "cancelled job unexpectedly completed"])
                    } catch is CancellationError { }
                    for name in ["poses.jsonl", "points.ply", "video-import.json"] {
                        try require(!FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path), "cancel published \(name)")
                    }
                    try require(FileManager.default.fileExists(atPath: output.appendingPathComponent("video-frames.json").path), "cancel must preserve input")
                    print("PASS real session cancellation: returned after cancellation acknowledgement; no prepared output")
                } else { throw PG.PrepareError.unsupported }
            } else if args[0] == "--prepare" {
                if #available(macOS 26.0, iOS 26.0, *) {
                    let result = try await PG.prepare(scanDirectory: output) { print("progress \(Int($0 * 100))%") }
                    print("PASS real session: \(result.validFrames) frames, \(result.points) points")
                } else { throw PG.PrepareError.unsupported }
            } else {
                let timeline = try PG.loadTimeline(scanDirectory: output)
                let raw = try JSONDecoder().decode([PG.RawPose].self, from: Data(contentsOf: source.appendingPathComponent("photogrammetry-poses.json")))
                let points = try readPLY(source.appendingPathComponent("photogrammetry-points.ply"))
                let result = try PG.writeReconstruction(scanDirectory: output, timeline: timeline, raw: raw, rawPoints: points)
                for name in ["poses.jsonl", "points.ply", "photogrammetry-points.ply"] {
                    try require(try Data(contentsOf: source.appendingPathComponent(name)) == Data(contentsOf: output.appendingPathComponent(name)), "real geometry replay differs: \(name)")
                }
                print("PASS real saved-result replay: \(result.validFrames) frames, \(result.points) points; pose and point bytes match Mac baseline")
            }
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}
