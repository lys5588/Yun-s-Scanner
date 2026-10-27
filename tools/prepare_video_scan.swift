// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
//
// Mac-only bridge from extracted ordinary-video frames to RealityKit Object Capture.
// It intentionally does not synthesize ARKit poses, depth, metres, ISO, or exposure.

import Foundation
import RealityKit
import ImageIO
import simd
import Darwin

private enum PrepareError: LocalizedError {
    case usage, unsupported, missing(String), malformed(String), reconstruction(String), ambiguousPose(String)
    var errorDescription: String? {
        switch self {
        case .usage: return "usage: prepare_video_scan EXTRACTED_IMAGES_DIR SCAN_DIR"
        case .unsupported: return "PhotogrammetrySession is not supported on this Mac"
        case .missing(let value): return "missing required input: \(value)"
        case .malformed(let value): return "invalid input: \(value)"
        case .reconstruction(let value): return "photogrammetry reconstruction failed: \(value)"
        case .ambiguousPose(let value): return "cannot establish a safe camera convention: \(value)"
        }
    }
}

private struct VideoFrame: Codable {
    let imageFile: String
    let timestamp: Double
}

private func validateTimeline(_ timeline: [VideoFrame]) throws {
    guard timeline.count >= 8 else { throw PrepareError.malformed("video-frames.json must contain at least 8 frames") }
    // Source PTS may begin before zero. Preserve that time origin; only ordering and
    // finite values are required for image-to-video correspondence and time differences.
    guard Set(timeline.map(\.imageFile)).count == timeline.count,
          timeline.allSatisfy({ $0.timestamp.isFinite }),
          zip(timeline, timeline.dropFirst()).allSatisfy({ pair in pair.0.timestamp < pair.1.timestamp }) else {
        throw PrepareError.malformed("video-frames.json requires unique imageFile names and finite strictly increasing source timestamps")
    }
}

private struct Intrinsics: Codable {
    let fx: Double, fy: Double, cx: Double, cy: Double
    let width: Int, height: Int
}

/// JSON-compatible subset of FrameRecord. It deliberately has the same wire keys, while
/// video-import.json records that this is not an ARKit/metre coordinate system.
private struct PoseRecord: Codable {
    let id: Int
    let timestamp: Double
    let transform: [Double]
    let intrinsics: Intrinsics
    let exposureDuration: Double
    let exposureOffsetEV: Double
    let iso: Double
    let ambientLux: Double?
    let estimatedBlurPx: Double
    let sharpness: Double
    let sharpnessRatio: Double
    let blurVerdict: String
    let imageFile: String
    let depthFile: String?
    let confidenceFile: String?
    let depthWidth: Int?
    let depthHeight: Int?
}

private struct RawPose: Codable {
    let sampleID: Int
    let imageFile: String
    let timestamp: Double
    let translation: [Float]
    let rotationIXIYIZR: [Float]
    let transformColumnMajor: [Float]
    let intrinsicsColumnMajor: [Float]?
}

private struct Drop: Codable {
    let imageFile: String
    let timestamp: Double
    let reason: String
}

private struct CandidateScore: Codable {
    let name: String
    let evaluatedFrames: Int
    let projectedPoints: Int
    let positiveDepthPoints: Int
    let inBoundsPoints: Int
}

private struct ImportManifest: Codable {
    let version: Int
    let method: String
    let sourceImagesDirectory: String
    let sourceTimingFile: String
    let coordinateSystem: String
    let unit: String
    let metricScale: Bool
    let normalizationCenter: [Float]
    let normalizationScale: Float
    let coordinateAdaptation: String
    let projectionCheck: [CandidateScore]
    let validFrames: [String]
    let droppedFrames: [Drop]
    let sourceCameraMetadata: String
    let sourceExposureAndISO: String
    let trainingFrameSelection: String
    let rawPoseFile: String
    let rawPointCloudFile: String
    let normalizedPointCloudFile: String
}

private struct Point {
    var position: SIMD3<Float>
    var rgb: SIMD3<UInt8>
}

private struct UsablePose {
    let sampleID: Int
    let fileName: String
    let timestamp: Double
    let matrix: simd_float4x4
    let intrinsics: simd_float3x3
    let imageSize: SIMD2<Int>
}

private func printStage(_ message: String) { print("[prepare-video-scan] \(message)") }

private func matrixColumnMajor(_ matrix: simd_float4x4) -> [Float] {
    (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
}

private func matrixColumnMajor(_ matrix: simd_float3x3) -> [Float] {
    (0..<3).flatMap { column in (0..<3).map { row in matrix[column][row] } }
}

private func matrixRowMajor(_ matrix: simd_float4x4) -> [Double] {
    (0..<4).flatMap { row in (0..<4).map { column in Double(matrix[column][row]) } }
}

private func imageSize(_ url: URL) throws -> SIMD2<Int> {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else {
        throw PrepareError.malformed("cannot read image dimensions for \(url.lastPathComponent)")
    }
    return SIMD2(width, height)
}

private func isFinite(_ matrix: simd_float3x3) -> Bool {
    (0..<3).allSatisfy { col in (0..<3).allSatisfy { row in matrix[col][row].isFinite } }
}

private func isFinite(_ matrix: simd_float4x4) -> Bool {
    (0..<4).allSatisfy { col in (0..<4).allSatisfy { row in matrix[col][row].isFinite } }
}

private func isFinite(_ point: SIMD3<Float>) -> Bool {
    point.x.isFinite && point.y.isFinite && point.z.isFinite
}

private func intrinsics(_ matrix: simd_float3x3, size: SIMD2<Int>) -> Intrinsics? {
    guard isFinite(matrix) else { return nil }
    let fx = Double(matrix[0][0]), fy = Double(matrix[1][1])
    let cx = Double(matrix[2][0]), cy = Double(matrix[2][1])
    guard fx > 0, fy > 0, cx >= 0, cy >= 0,
          cx <= Double(size.x), cy <= Double(size.y) else { return nil }
    return Intrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: size.x, height: size.y)
}

private func yzFlip() -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, -1, 0, 0),
                                SIMD4(0, 0, -1, 0), SIMD4(0, 0, 0, 1)))
}

/// Scores two explicit interpretations against the returned sparse cloud. Candidate `direct`
/// treats the reported pose as GL-style c2w. `local_yz_flip` maps a +Z-forward/+Y-down local
/// camera basis into that GL-style convention. We do not choose when the evidence is weak.
private func scoreCandidate(name: String, poses: [UsablePose], points: [Point], flipLocalYZ: Bool) -> CandidateScore {
    guard !poses.isEmpty, !points.isEmpty else {
        return CandidateScore(name: name, evaluatedFrames: 0, projectedPoints: 0, positiveDepthPoints: 0, inBoundsPoints: 0)
    }
    let selectedPoses = Array(poses.prefix(24))
    let step = max(1, points.count / 20_000)
    var projected = 0, positive = 0, inBounds = 0
    let localFlip = yzFlip()
    for pose in selectedPoses {
        let c2w = flipLocalYZ ? pose.matrix * localFlip : pose.matrix
        let w2c = c2w.inverse
        let fx = pose.intrinsics[0][0], fy = pose.intrinsics[1][1]
        let cx = pose.intrinsics[2][0], cy = pose.intrinsics[2][1]
        for index in Swift.stride(from: 0, to: points.count, by: step) {
            let p = points[index].position
            let camera = w2c * SIMD4(p.x, p.y, p.z, 1)
            projected += 1
            // GL camera convention: forward is -Z; pixel y grows downwards.
            let depth = -camera.z
            guard depth.isFinite, depth > 1e-5 else { continue }
            positive += 1
            let x = fx * camera.x / depth + cx
            let y = -fy * camera.y / depth + cy
            if x >= 0, x < Float(pose.imageSize.x), y >= 0, y < Float(pose.imageSize.y) { inBounds += 1 }
        }
    }
    return CandidateScore(name: name, evaluatedFrames: selectedPoses.count, projectedPoints: projected,
                          positiveDepthPoints: positive, inBoundsPoints: inBounds)
}

private func chooseConvention(poses: [UsablePose], points: [Point]) throws -> (Bool, [CandidateScore]) {
    let direct = scoreCandidate(name: "direct_pose_as_gl_c2w", poses: poses, points: points, flipLocalYZ: false)
    let flipped = scoreCandidate(name: "local_yz_flip_to_gl_c2w", poses: poses, points: points, flipLocalYZ: true)
    let scores = [direct, flipped]
    let ordered = scores.sorted { $0.inBoundsPoints > $1.inBoundsPoints }
    guard let winner = ordered.first, let runnerUp = ordered.dropFirst().first,
          winner.evaluatedFrames >= 8,
          winner.inBoundsPoints >= max(64, winner.evaluatedFrames * 5),
          winner.positiveDepthPoints >= winner.inBoundsPoints,
          winner.inBoundsPoints >= runnerUp.inBoundsPoints * 3 / 2 + 10 else {
        throw PrepareError.ambiguousPose("projection candidates are not sufficiently separated: \(scores)")
    }
    return (winner.name == "local_yz_flip_to_gl_c2w", scores)
}

private func normalized(points: [Point]) throws -> (center: SIMD3<Float>, scale: Float, points: [Point]) {
    guard !points.isEmpty else { throw PrepareError.reconstruction("point cloud is empty") }
    let center = points.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.position } / Float(points.count)
    let radius = points.map { simd_length($0.position - center) }.sorted()
    // A high percentile avoids one sparse outlier deciding every Gaussian's numeric scale.
    let reference = radius[min(radius.count - 1, Int(Float(radius.count - 1) * 0.95))]
    guard reference.isFinite, reference > 1e-6 else { throw PrepareError.reconstruction("point cloud has no spatial extent") }
    let scale: Float = 1 / reference
    return (center, scale, points.map { Point(position: ($0.position - center) * scale, rgb: $0.rgb) })
}

private func appendLittleEndian(_ value: Float, to data: inout Data) {
    var bits = value.bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
}

private func writePLY(_ points: [Point], to url: URL) throws {
    let header = "ply\nformat binary_little_endian 1.0\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
    var data = Data(header.utf8)
    data.reserveCapacity(data.count + points.count * 15)
    for point in points {
        appendLittleEndian(point.position.x, to: &data)
        appendLittleEndian(point.position.y, to: &data)
        appendLittleEndian(point.position.z, to: &data)
        data.append(point.rgb.x); data.append(point.rgb.y); data.append(point.rgb.z)
    }
    try data.write(to: url, options: .atomic)
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func resolveImage(_ entry: VideoFrame, imagesDir: URL) -> URL? {
    let direct = imagesDir.appendingPathComponent(entry.imageFile)
    if FileManager.default.fileExists(atPath: direct.path) { return direct }
    let basename = imagesDir.appendingPathComponent((entry.imageFile as NSString).lastPathComponent)
    return FileManager.default.fileExists(atPath: basename.path) ? basename : nil
}

private func projection(_ point: SIMD3<Float>, c2w: simd_float4x4, k: simd_float3x3) -> SIMD2<Float>? {
    let camera = c2w.inverse * SIMD4(point.x, point.y, point.z, 1)
    let depth = -camera.z
    guard depth.isFinite, depth > 1e-5 else { return nil }
    return SIMD2(k[0][0] * camera.x / depth + k[2][0],
                 -k[1][1] * camera.y / depth + k[2][1])
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PrepareError.reconstruction("self-test failed: \(message)") }
}

/// Exercises the same projection chooser, normalization and binary writer used for real data.
/// It is deliberately synthetic: it verifies convention math and file bytes, not reconstruction
/// quality from photographs.
private func selfTest() throws {
    let signedTimeline = (0..<8).map { VideoFrame(imageFile: "frame_\($0).jpg", timestamp: Double($0) * 0.5 - 2) }
    try validateTimeline(signedTimeline)
    for invalidTime in [signedTimeline[6].timestamp, Double.nan, Double.infinity] {
        var invalidTimeline = signedTimeline
        invalidTimeline[7] = VideoFrame(imageFile: "frame_7.jpg", timestamp: invalidTime)
        do {
            try validateTimeline(invalidTimeline)
            throw PrepareError.reconstruction("self-test failed: invalid source timestamp was accepted")
        } catch PrepareError.malformed { }
    }
    let size = SIMD2<Int>(200, 160)
    let k = simd_float3x3(columns: (SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(100, 80, 1)))
    let poses = (0..<8).map { index in
        UsablePose(sampleID: index, fileName: "frame_\(index).jpg", timestamp: Double(index),
                   matrix: matrix_identity_float4x4, intrinsics: k, imageSize: size)
    }
    var glPoints: [Point] = []
    for index in 0..<80 {
        let x = Float(index % 10 - 5) * 0.08
        let y = Float(index / 10 - 4) * 0.08
        glPoints.append(Point(position: SIMD3<Float>(x, y, -2), rgb: SIMD3<UInt8>(20, 40, 60)))
    }
    let cvPoints: [Point] = glPoints.map {
        Point(position: SIMD3<Float>($0.position.x, -$0.position.y, -$0.position.z), rgb: $0.rgb)
    }
    let (glFlip, glScores) = try chooseConvention(poses: poses, points: glPoints)
    try expect(!glFlip && glScores[0].inBoundsPoints > glScores[1].inBoundsPoints, "known GL c2w must select direct")
    let (cvFlip, cvScores) = try chooseConvention(poses: poses, points: cvPoints)
    try expect(cvFlip && cvScores[1].inBoundsPoints > cvScores[0].inBoundsPoints, "known CV c2w must select local Y/Z flip")
    do {
        var ambiguousPoints = glPoints
        ambiguousPoints.append(contentsOf: cvPoints)
        _ = try chooseConvention(poses: poses, points: ambiguousPoints)
        throw PrepareError.reconstruction("self-test failed: ambiguous projection was accepted")
    } catch PrepareError.ambiguousPose { }

    var translated = matrix_identity_float4x4
    translated.columns.3 = SIMD4(10, -3, 2, 1)
    let world = glPoints.map { Point(position: $0.position + SIMD3(10, -3, 2), rgb: $0.rgb) }
    let before = try projection(world[0].position, c2w: translated, k: k).unwrap("pre-normalization projection")
    let norm = try normalized(points: world)
    var normalizedCamera = translated
    let originalTranslation = SIMD3(translated.columns.3.x, translated.columns.3.y, translated.columns.3.z)
    normalizedCamera.columns.3 = SIMD4((originalTranslation - norm.center) * norm.scale, 1)
    let after = try projection(norm.points[0].position, c2w: normalizedCamera, k: k).unwrap("post-normalization projection")
    let dx = before.x - after.x
    let dy = before.y - after.y
    try expect(dx * dx + dy * dy < 1e-8, "normalization must preserve camera projection")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prepare-video-scan-self-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ply = directory.appendingPathComponent("points.ply")
    try writePLY([Point(position: SIMD3(1.25, -2.5, 3.75), rgb: SIMD3(1, 2, 3))], to: ply)
    let bytes = try Data(contentsOf: ply)
    let marker = Data("end_header\n".utf8)
    guard let end = bytes.range(of: marker) else { throw PrepareError.reconstruction("self-test failed: PLY header") }
    let header = String(data: bytes[..<end.upperBound], encoding: .ascii) ?? ""
    try expect(header.contains("format binary_little_endian 1.0") &&
               header.contains("property float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue"),
               "PLY header must match ScanLibrary reader")
    try expect(bytes.count == end.upperBound + 15, "PLY vertex stride must be 15 bytes")
    let payload = bytes.subdata(in: end.upperBound..<bytes.count)
    let x = payload.withUnsafeBytes { raw in Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))) }
    try expect(abs(x - 1.25) < 1e-6 && payload[12] == 1 && payload[13] == 2 && payload[14] == 3,
               "PLY payload must be little-endian xyz float32 + RGB uint8")
    printStage("self-test passed: source timestamps, convention selection, ambiguity rejection, normalization, PLY")
}

private extension Optional {
    func unwrap(_ label: String) throws -> Wrapped {
        guard let value = self else { throw PrepareError.reconstruction("self-test failed: \(label)") }
        return value
    }
}

private func run(imagesDir: URL, scanDir: URL) async throws {
    guard PhotogrammetrySession.isSupported else { throw PrepareError.unsupported }
    let expectedImages = scanDir.appendingPathComponent("images", isDirectory: true)
    guard imagesDir.standardizedFileURL.resolvingSymlinksInPath() ==
            expectedImages.standardizedFileURL.resolvingSymlinksInPath() else {
        throw PrepareError.malformed("extracted images must be in SCAN_DIR/images so the scan remains portable")
    }
    let timingURL = scanDir.appendingPathComponent("video-frames.json")
    guard FileManager.default.fileExists(atPath: imagesDir.path) else { throw PrepareError.missing(imagesDir.path) }
    guard FileManager.default.fileExists(atPath: timingURL.path) else { throw PrepareError.missing(timingURL.path) }
    let timeline = try JSONDecoder().decode([VideoFrame].self, from: Data(contentsOf: timingURL))
    try validateTimeline(timeline)
    let resolved = timeline.compactMap { entry -> (VideoFrame, URL)? in resolveImage(entry, imagesDir: imagesDir).map { (entry, $0) } }
    guard resolved.count >= 8 else { throw PrepareError.missing("fewer than 8 extracted images are available") }
    printStage("input: \(resolved.count)/\(timeline.count) extracted frames; no source images will be copied or overwritten")

    var configuration = PhotogrammetrySession.Configuration()
    configuration.sampleOrdering = .sequential
    let session = try PhotogrammetrySession(input: imagesDir, configuration: configuration)
    printStage("starting PhotogrammetrySession poses + sparse point cloud")
    try session.process(requests: [.poses, .pointCloud])
    var posesResult: PhotogrammetrySession.Poses?
    var cloudResult: PhotogrammetrySession.PointCloud?
    outputLoop: for try await output in session.outputs {
        switch output {
        case .inputComplete: printStage("image ingestion complete")
        case .requestProgress(let request, let fraction): printStage("\(request): \(Int(fraction * 100))%")
        case .requestComplete(_, let result):
            switch result {
            case .poses(let poses): posesResult = poses; printStage("camera poses completed: \(poses.posesBySample.count)")
            case .pointCloud(let cloud): cloudResult = cloud; printStage("sparse points completed: \(cloud.points.count)")
            default: break
            }
        case .requestError(let request, let error): throw PrepareError.reconstruction("\(request): \(error.localizedDescription)")
        case .invalidSample(let id, let reason): printStage("invalid sample \(id): \(reason)")
        case .skippedSample(let id): printStage("skipped sample \(id)")
        case .processingComplete:
            printStage("photogrammetry processing complete")
            break outputLoop
        case .processingCancelled: throw PrepareError.reconstruction("cancelled")
        default: break
        }
    }
    guard let posesResult else { throw PrepareError.reconstruction("no poses result") }
    guard let cloudResult, !cloudResult.points.isEmpty else { throw PrepareError.reconstruction("no sparse point cloud result") }

    guard cloudResult.points.allSatisfy({ isFinite($0.position) }) else {
        throw PrepareError.reconstruction("sparse point cloud contains non-finite coordinates")
    }
    let rawPoints = cloudResult.points.map { Point(position: $0.position, rgb: SIMD3($0.color.x, $0.color.y, $0.color.z)) }
    let byName = Dictionary(uniqueKeysWithValues: resolved.map { ($0.1.lastPathComponent, $0.0) })
    var usable: [UsablePose] = []
    var raw: [RawPose] = []
    var dropped: [Drop] = timeline.compactMap { entry in
        resolveImage(entry, imagesDir: imagesDir) == nil ? Drop(imageFile: entry.imageFile, timestamp: entry.timestamp, reason: "image_missing") : nil
    }
    for (id, pose) in posesResult.posesBySample.sorted(by: { $0.key < $1.key }) {
        guard let url = posesResult.urlsBySample[id], let source = byName[url.lastPathComponent] else { continue }
        let matrix = pose.transform.matrix
        let rawK = pose.intrinsics
        guard isFinite(matrix), isFinite(pose.translation),
              pose.rotation.imag.x.isFinite, pose.rotation.imag.y.isFinite,
              pose.rotation.imag.z.isFinite, pose.rotation.real.isFinite,
              rawK.map(isFinite) ?? true else {
            throw PrepareError.reconstruction("pose sample \(id) contains non-finite values")
        }
        raw.append(RawPose(sampleID: id, imageFile: source.imageFile, timestamp: source.timestamp,
                           translation: [pose.translation.x, pose.translation.y, pose.translation.z],
                           rotationIXIYIZR: [pose.rotation.imag.x, pose.rotation.imag.y, pose.rotation.imag.z, pose.rotation.real],
                           transformColumnMajor: matrixColumnMajor(matrix),
                           intrinsicsColumnMajor: rawK.map(matrixColumnMajor)))
        guard let k = rawK, let size = try? imageSize(url), intrinsics(k, size: size) != nil else {
            dropped.append(Drop(imageFile: source.imageFile, timestamp: source.timestamp, reason: "missing_or_invalid_intrinsics"))
            continue
        }
        usable.append(UsablePose(sampleID: id, fileName: url.lastPathComponent, timestamp: source.timestamp,
                                 matrix: matrix, intrinsics: k, imageSize: size))
    }
    try writeJSON(raw, to: scanDir.appendingPathComponent("photogrammetry-poses.json"))
    try writePLY(rawPoints, to: scanDir.appendingPathComponent("photogrammetry-points.ply"))
    guard usable.count >= 8 else { throw PrepareError.reconstruction("only \(usable.count) frames have pose and estimated intrinsics; need 8") }
    guard let referenceSize = usable.first?.imageSize,
          usable.allSatisfy({ $0.imageSize == referenceSize }) else {
        throw PrepareError.malformed("training frames must have one common image resolution")
    }
    let (flipLocalYZ, scores) = try chooseConvention(poses: usable, points: rawPoints)
    printStage("projection check selected \(flipLocalYZ ? "local_yz_flip_to_gl_c2w" : "direct_pose_as_gl_c2w")")
    let norm = try normalized(points: rawPoints)
    try writePLY(norm.points, to: scanDir.appendingPathComponent("points.ply"))

    let localFlip = yzFlip()
    var records: [PoseRecord] = []
    for pose in usable.sorted(by: { $0.timestamp < $1.timestamp }) {
        let c2w = flipLocalYZ ? pose.matrix * localFlip : pose.matrix
        var adjusted = c2w
        let translation = SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
        adjusted.columns.3 = SIMD4((translation - norm.center) * norm.scale, 1)
        guard let k = intrinsics(pose.intrinsics, size: pose.imageSize) else { continue }
        records.append(PoseRecord(id: pose.sampleID, timestamp: pose.timestamp, transform: matrixRowMajor(adjusted), intrinsics: k,
                                  exposureDuration: 0, exposureOffsetEV: 0, iso: 0, ambientLux: nil,
                                  estimatedBlurPx: 0, sharpness: 0, sharpnessRatio: 1, blurVerdict: "keep",
                                  imageFile: pose.fileName, depthFile: nil, confidenceFile: nil, depthWidth: nil, depthHeight: nil))
    }
    guard records.count >= 8 else { throw PrepareError.reconstruction("fewer than 8 normalized pose records remain") }
    let jsonl = JSONEncoder(); jsonl.outputFormatting = [.sortedKeys]
    let poseURL = scanDir.appendingPathComponent("poses.jsonl")
    var rows = Data()
    for record in records { rows.append(try jsonl.encode(record)); rows.append(0x0A) }
    try rows.write(to: poseURL, options: .atomic)
    let validNames = Set(records.map(\.imageFile))
    for entry in timeline where !validNames.contains((entry.imageFile as NSString).lastPathComponent) && !dropped.contains(where: { $0.imageFile == entry.imageFile }) {
        dropped.append(Drop(imageFile: entry.imageFile, timestamp: entry.timestamp, reason: "no_photogrammetry_pose"))
    }
    let manifest = ImportManifest(version: 1, method: "RealityKit.PhotogrammetrySession",
                                  sourceImagesDirectory: "images", sourceTimingFile: "video-frames.json",
                                  coordinateSystem: "photogrammetry_estimated_c2w_adapted_to_gl_camera_basis",
                                  unit: "arbitrary_photogrammetry_unit_normalized", metricScale: false,
                                  normalizationCenter: [norm.center.x, norm.center.y, norm.center.z], normalizationScale: norm.scale,
                                  coordinateAdaptation: flipLocalYZ ? "local_yz_flip_to_gl_c2w" : "direct_pose_as_gl_c2w",
                                  projectionCheck: scores, validFrames: records.map(\.imageFile), droppedFrames: dropped,
                                  sourceCameraMetadata: "ordinary video: no ARKit pose, depth, or physical-scale metadata was supplied",
                                  sourceExposureAndISO: "unknown; poses.jsonl writes zero placeholders only for legacy FrameRecord compatibility",
                                  trainingFrameSelection: "captured",
                                  rawPoseFile: "photogrammetry-poses.json", rawPointCloudFile: "photogrammetry-points.ply",
                                  normalizedPointCloudFile: "points.ply")
    try writeJSON(manifest, to: scanDir.appendingPathComponent("video-import.json"))
    printStage("wrote \(records.count) training pose records and \(norm.points.count) normalized sparse points")
}

@main private struct PrepareVideoScan {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--self-test"] {
                try selfTest()
                return
            }
            guard args.count == 2 else { throw PrepareError.usage }
            try await run(imagesDir: URL(fileURLWithPath: args[0], isDirectory: true),
                          scanDir: URL(fileURLWithPath: args[1], isDirectory: true))
        } catch {
            fputs("prepare-video-scan: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
