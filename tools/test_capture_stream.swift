// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import Foundation
import AVFoundation
import CoreVideo

enum Failure: Error { case buffer, expectation, archive, unreadable }

final class Readiness: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func allow() { lock.lock(); value = true; lock.unlock() }
    func block() { lock.lock(); value = false; lock.unlock() }
}

func decodedTimes(_ url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1 else {
        FileHandle.standardError.write(Data("AVAssetReader found \(tracks.count) tracks in \(url.path)\n".utf8))
        throw Failure.unreadable
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[0],
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else {
        FileHandle.standardError.write(Data("AVAssetReader start failed: \(String(describing: reader.error))\n".utf8))
        throw Failure.unreadable
    }
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let image = CMSampleBufferGetImageBuffer(sample) else {
            FileHandle.standardError.write(Data("Decoded sample has no pixel buffer\n".utf8))
            throw Failure.unreadable
        }
        guard CVPixelBufferGetWidth(image) == 320, CVPixelBufferGetHeight(image) == 240 else {
            FileHandle.standardError.write(Data("Unexpected decoded dimensions \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))\n".utf8))
            throw Failure.unreadable
        }
        times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }
    guard reader.status == .completed else {
        FileHandle.standardError.write(Data("AVAssetReader status \(reader.status.rawValue): \(String(describing: reader.error))\n".utf8))
        throw Failure.unreadable
    }
    return times
}

func makePixelBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw Failure.buffer }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 127,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    guard let pool = PixelBufferUtil.makePool(width: 320, height: 240,
                                              pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
          let copy = PixelBufferUtil.clone(buffer, pool: pool),
          let matrix = CVBufferCopyAttachment(copy, kCVImageBufferYCbCrMatrixKey, nil),
          matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String else { throw Failure.buffer }
    return copy
}

func frame(_ id: Int, timestamp: Double) -> CaptureStreamFrame {
    CaptureStreamFrame(frameID: id, timestamp: timestamp, videoPTS: nil, videoFile: nil, videoWritten: false,
                       dropReason: nil, intrinsics: CameraIntrinsics(fx: 200, fy: 200, cx: 160, cy: 120, width: 320, height: 240),
                       transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], trackingState: "normal",
                       depthFile: nil, confidenceFile: nil, depthWidth: nil, depthHeight: nil)
}

func saveMetadata(at directory: URL, segments: [String]) throws {
    let metadata: [String: Any] = ["streamCapture": ["schemaVersion": 1, "status": "complete",
                                                   "manifestFile": "frames.jsonl", "videoSegments": segments]]
    try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("capture-meta.json"))
}

@main enum CaptureStreamRegression {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pixel = try makePixelBuffer()
        let recorder = try CaptureStreamRecorder(sessionDir: root)
        var firstFrame = frame(1, timestamp: 12)
        firstFrame.depthWidth = 1; firstFrame.depthHeight = 1
        let first = try await recorder.append(CaptureStreamPacket(manifest: firstFrame, color: pixel,
                                            depth: Data([0, 0, 128, 63]), confidence: Data([2])))
        guard first.videoWritten, first.videoPTS == 0, first.videoFile == "color.mov",
              first.depthFile == "depth/continuous/00000001.f32",
              first.confidenceFile == "depth/continuous/00000001.u8" else { throw Failure.expectation }
        // A non-frame-grid timestamp verifies that elapsed capture time is not renumbered.
        try await Task.sleep(for: .milliseconds(40))
        let later = try await recorder.append(CaptureStreamPacket(manifest: frame(2, timestamp: 12.0376),
                                                                  color: pixel, depth: nil, confidence: nil))
        guard later.videoWritten, abs(later.videoPTS! - 0.0376) < 0.002 else { throw Failure.expectation }
        try await recorder.finishSegment()
        let second = try await recorder.append(CaptureStreamPacket(manifest: frame(3, timestamp: 25),
                                                                   color: pixel, depth: nil, confidence: nil))
        guard second.videoWritten, second.videoPTS == 0, second.videoFile == "color-0001.mov" else { throw Failure.expectation }
        let segments = try await recorder.finish()
        guard segments == ["color.mov", "color-0001.mov"],
              try await recorder.finish() == segments,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("depth/continuous/00000001.f32").path) else {
            throw Failure.archive
        }
        let firstTimes = try await decodedTimes(root.appendingPathComponent(segments[0]))
        let secondTimes = try await decodedTimes(root.appendingPathComponent(segments[1]))
        guard firstTimes.count == 2, abs(firstTimes[0]) < 0.002, abs(firstTimes[1] - 0.0376) < 0.002,
              secondTimes.count == 1, abs(secondTimes[0]) < 0.002 else { throw Failure.unreadable }
        do {
            _ = try await recorder.append(CaptureStreamPacket(manifest: frame(4, timestamp: 26), color: pixel, depth: nil, confidence: nil))
            throw Failure.expectation
        } catch CaptureStreamRecorder.RecorderError.closed { }
        try saveMetadata(at: root, segments: segments)
        let jsonl = try String(contentsOf: root.appendingPathComponent("frames.jsonl"), encoding: .utf8)
        guard jsonl.split(separator: "\n").count == 3 else { throw Failure.archive }
        print("PASS: production NV12 clone/colour attachments, recorder, decoded PTS, depth, resumed segments and close")

        let pressuredRoot = root.appendingPathComponent("pressure", isDirectory: true)
        try FileManager.default.createDirectory(at: pressuredRoot, withIntermediateDirectories: true)
        let readiness = Readiness()
        let pressured = try CaptureStreamRecorder(sessionDir: pressuredRoot, writerReadyOverride: { readiness.get() })
        let dropped = try await pressured.append(CaptureStreamPacket(manifest: frame(1, timestamp: 1),
                                                                      color: pixel, depth: nil, confidence: nil))
        guard !dropped.videoWritten, dropped.dropReason == "writer_backpressure" else { throw Failure.expectation }
        readiness.allow()
        let accepted = try await pressured.append(CaptureStreamPacket(manifest: frame(2, timestamp: 1.1),
                                                                       color: pixel, depth: nil, confidence: nil))
        guard accepted.videoWritten, accepted.videoPTS == 0 else { throw Failure.expectation }
        try await pressured.finishSegment()
        readiness.block()
        _ = try await pressured.append(CaptureStreamPacket(manifest: frame(3, timestamp: 2),
                                                            color: pixel, depth: nil, confidence: nil))
        let pressureSegments = try await pressured.finish()
        guard pressureSegments == ["color.mov"],
              !FileManager.default.fileExists(atPath: pressuredRoot.appendingPathComponent("color-0001.mov").path) else {
            throw Failure.archive
        }
        let pressureTimes = try await decodedTimes(pressuredRoot.appendingPathComponent("color.mov"))
        guard pressureTimes.count == 1, pressureTimes[0] == 0 else { throw Failure.unreadable }
        try saveMetadata(at: pressuredRoot, segments: pressureSegments)
        print("PASS: first-frame backpressure adds no phantom video samples; empty resumed segments are removed")

        let emptyRoot = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let empty = try CaptureStreamRecorder(sessionDir: emptyRoot, writerReadyOverride: { false })
        _ = try await empty.append(CaptureStreamPacket(manifest: frame(1, timestamp: 1), color: pixel, depth: nil, confidence: nil))
        for _ in 0..<2 {
            do {
                _ = try await empty.finish()
                throw Failure.expectation
            } catch CaptureStreamRecorder.RecorderError.noSamples { }
        }
        do {
            _ = try await empty.append(CaptureStreamPacket(manifest: frame(2, timestamp: 2), color: pixel, depth: nil, confidence: nil))
            throw Failure.expectation
        } catch CaptureStreamRecorder.RecorderError.noSamples { }
        guard await empty.segments().isEmpty,
              !FileManager.default.fileExists(atPath: emptyRoot.appendingPathComponent("color.mov").path),
              FileManager.default.fileExists(atPath: emptyRoot.appendingPathComponent("frames.jsonl").path) else { throw Failure.archive }
        print("PASS: zero-sample recording fails persistently, removes invalid MOV and preserves diagnostic manifest")
    }
}
