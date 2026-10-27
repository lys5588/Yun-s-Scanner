// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.

import Foundation
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct VideoExtractionResult: Sendable {
    let frameCount: Int
    let duration: Double
    let sourceName: String
}

/// Extracts real presentation samples from an owned source movie. The coordinator owns
/// copying/security-scoped access and publication of the staging scan directory.
nonisolated enum VideoFrameExtractor {
    private struct ExtractionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Frame: Codable {
        let imageFile: String
        let timestamp: Double
        let presentationTimeValue: Int64
        let presentationTimeTimescale: Int32
    }

    private struct SourceMetadata: Encodable {
        let version = 1
        let sourceName: String
        let sourceSHA256: String
        let sourceBytes: Int64
        let duration: Double
        let trackStartTime: Double
        let firstSourcePresentationTime: Double
        let lastSourcePresentationTime: Double
        let sourceSampleCount: Int
        let encodedWidth: Int
        let encodedHeight: Int
        let preferredTransform: [Double]
        let sourceColorPrimaries: String?
        let sourceTransferFunction: String?
        let sourceYCbCrMatrix: String?
        let samplingInterval: Double
        let maximumFrames: Int
        let extractedFrames: Int
        let outputWidth: Int
        let outputHeight: Int
        let outputColorSpace = "sRGB SDR, 8-bit JPEG"
        let imageOrientation = "up; preferredTransform applied once to pixels by AVAssetImageGenerator"
        let extractionMethod = "AVAssetReader compressed-sample PTS index; AVAssetImageGenerator exact-time forceSDR; color-managed sRGB conversion"
        let timingPolicy = "Preserve signed AVFoundation presentation timestamps after container edit lists; no zero-origin rebasing or synthetic frame grid"
        let cameraIntrinsics = "Unknown; estimate from the extracted, oriented JPEGs during photogrammetry"
        let physicalScale = "Unknown; ordinary video supplies no ARKit pose, depth, or metric scale"
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func extract(sourceURL: URL, scanDirectory: URL, maximumFrames: Int,
                        progress: @Sendable @escaping (Double) -> Void) async throws -> VideoExtractionResult {
        // Explicitly leave the UI executor even when the app enables default MainActor isolation.
        let work = Task.detached(priority: .userInitiated) {
            try await perform(sourceURL: sourceURL, scanDirectory: scanDirectory,
                              maximumFrames: maximumFrames, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func perform(sourceURL: URL, scanDirectory: URL, maximumFrames: Int,
                                progress: @Sendable @escaping (Double) -> Void) async throws -> VideoExtractionResult {
        try Task.checkCancellation()
        let limit = min(200, maximumFrames)
        guard limit >= 8 else { throw ExtractionError(message: "Photogrammetry must support at least eight input images.") }
        let fm = FileManager.default
        let images = scanDirectory.appendingPathComponent("images", isDirectory: true)
        let timingURL = scanDirectory.appendingPathComponent("video-frames.json")
        let sourceMetadataURL = scanDirectory.appendingPathComponent("video-source.json")
        guard !fm.fileExists(atPath: images.path), !fm.fileExists(atPath: timingURL.path),
              !fm.fileExists(atPath: sourceMetadataURL.path) else {
            throw ExtractionError(message: "The staging scan already contains extraction outputs.")
        }
        let sourceAttributes = try fm.attributesOfItem(atPath: sourceURL.path)
        guard let sourceBytes = (sourceAttributes[.size] as? NSNumber)?.int64Value, sourceBytes > 0 else {
            throw ExtractionError(message: "The source movie is empty or unreadable.")
        }
        let sourceHash = try hash(sourceURL)
        progress(0.05)
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExtractionError(message: "The selected file has no readable video track.")
        }
        let timeRange = try await track.load(.timeRange)
        let duration = timeRange.duration.seconds
        guard duration.isFinite, duration > 0, duration <= 180 else {
            throw ExtractionError(message: "Choose a video longer than zero and no more than 180 seconds.")
        }
        let transform = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        let extensions: NSDictionary? = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) } as NSDictionary?
        func color(_ key: CFString) -> String? { extensions?[key] as? String }
        // AVAssetImageGenerator supports orthogonal rotations. Reject a nonstandard
        // matrix rather than silently losing a crop, shear, or mirrored orientation.
        let coefficients = [transform.a, transform.b, transform.c, transform.d]
        let orthogonal = coefficients.allSatisfy { abs($0.rounded() - $0) < 0.0001 && abs($0) <= 1.0001 }
            && abs(transform.a * transform.d - transform.b * transform.c - 1) < 0.0001
            && abs(transform.a * transform.a + transform.b * transform.b - 1) < 0.0001
            && abs(transform.c * transform.c + transform.d * transform.d - 1) < 0.0001
        guard orthogonal, transform.tx.isFinite, transform.ty.isFinite else {
            throw ExtractionError(message: "This video has an unsupported mirrored or non-orthogonal display transform.")
        }
        let sourceTimes = try presentationTimes(asset: asset, track: track)
        guard let first = sourceTimes.first, let last = sourceTimes.last, sourceTimes.count >= 8 else {
            throw ExtractionError(message: "The video contains fewer than eight distinct presentation samples.")
        }
        let span = last.seconds - first.seconds
        guard span.isFinite, span <= 180 else { throw ExtractionError(message: "The video presentation span exceeds 180 seconds.") }
        // Leave one interval of headroom for snapping forward to real samples; using
        // span/(limit-1) plus repeated rounding can lose the eighth required view.
        let interval = max(0.5, span / Double(limit))
        var selected: [CMTime] = []
        for time in sourceTimes {
            if selected.isEmpty || time.seconds - selected.last!.seconds >= interval - 0.0000001 {
                selected.append(time)
                if selected.count == limit { break }
            }
        }
        guard selected.count >= 8 else {
            throw ExtractionError(message: "The video is too short to provide eight frames at least half a second apart.")
        }
        progress(0.1)
        try Task.checkCancellation()
        try fm.createDirectory(at: images, withIntermediateDirectories: false)
        var succeeded = false
        defer {
            if !succeeded {
                try? fm.removeItem(at: images)
                try? fm.removeItem(at: timingURL)
                try? fm.removeItem(at: sourceMetadataURL)
            }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.apertureMode = .encodedPixels
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // This performs native HLG/PQ -> SDR transfer conversion; it is not retagging.
        // forceSDR retains source primaries, so writeJPEG also color-converts to sRGB.
        generator.dynamicRangePolicy = .forceSDR
        var frames: [Frame] = []
        var outputSize: (Int, Int)?
        try await withTaskCancellationHandler {
            for (index, time) in selected.enumerated() {
                try Task.checkCancellation()
                let result = try await generator.image(at: time)
                try Task.checkCancellation()
                guard result.actualTime.isNumeric, CMTimeCompare(result.actualTime, time) == 0,
                      frames.last.map({ result.actualTime.seconds > $0.timestamp }) ?? true else {
                    throw ExtractionError(message: "The decoder could not preserve the requested source presentation timestamp.")
                }
                let image = result.image
                if let expected = outputSize, expected != (image.width, image.height) {
                    throw ExtractionError(message: "The video changes resolution during extraction.")
                }
                outputSize = (image.width, image.height)
                let name = String(format: "frame_%06d.jpg", index + 1)
                try autoreleasepool { try writeJPEG(image, to: images.appendingPathComponent(name)) }
                frames.append(Frame(imageFile: name, timestamp: result.actualTime.seconds,
                                    presentationTimeValue: result.actualTime.value,
                                    presentationTimeTimescale: result.actualTime.timescale))
                progress(0.1 + 0.85 * Double(index + 1) / Double(selected.count))
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        try Task.checkCancellation()
        let finalAttributes = try fm.attributesOfItem(atPath: sourceURL.path)
        guard (finalAttributes[.size] as? NSNumber)?.int64Value == sourceBytes,
              (finalAttributes[.modificationDate] as? Date) == (sourceAttributes[.modificationDate] as? Date),
              let outputSize else { throw ExtractionError(message: "The source movie changed during extraction.") }
        let metadata = SourceMetadata(sourceName: sourceURL.lastPathComponent, sourceSHA256: sourceHash,
                                      sourceBytes: sourceBytes, duration: duration, trackStartTime: timeRange.start.seconds,
                                      firstSourcePresentationTime: first.seconds, lastSourcePresentationTime: last.seconds,
                                      sourceSampleCount: sourceTimes.count, encodedWidth: Int(size.width), encodedHeight: Int(size.height),
                                      preferredTransform: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].map(Double.init),
                                      sourceColorPrimaries: color(kCMFormatDescriptionExtension_ColorPrimaries),
                                      sourceTransferFunction: color(kCMFormatDescriptionExtension_TransferFunction),
                                      sourceYCbCrMatrix: color(kCMFormatDescriptionExtension_YCbCrMatrix),
                                      samplingInterval: interval, maximumFrames: limit, extractedFrames: frames.count,
                                      outputWidth: outputSize.0, outputHeight: outputSize.1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(frames).write(to: timingURL, options: .atomic)
        try encoder.encode(metadata).write(to: sourceMetadataURL, options: .atomic)
        try Task.checkCancellation()
        succeeded = true
        progress(1)
        return VideoExtractionResult(frameCount: frames.count, duration: duration, sourceName: sourceURL.lastPathComponent)
    }

    private static func presentationTimes(asset: AVAsset, track: AVAssetTrack) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractionError(message: "Cannot index this video track.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExtractionError(message: "Cannot read the video samples.") }
        defer { reader.cancelReading() }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // AVAssetReader also emits zero-sample discontinuity/end markers; these
            // are not images and may intentionally carry an invalid presentation time.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            // Output PTS includes the container edit-list offset. The raw sample PTS
            // can instead refer to the media timeline (e.g. 0.2 for a movie starting
            // at 5.0 seconds), and cannot be used for exact asset image requests.
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            guard time.isNumeric, time.seconds.isFinite, time.epoch == 0 else {
                throw ExtractionError(message: "The video contains an invalid presentation timestamp.")
            }
            times.append(time)
            guard times.count <= 100_000 else { throw ExtractionError(message: "The video contains too many samples to process safely.") }
        }
        guard reader.status == .completed else { throw reader.error ?? ExtractionError(message: "Reading video timestamps did not complete.") }
        // Compressed B-frames may arrive in decode order, not presentation order.
        times.sort { CMTimeCompare($0, $1) < 0 }
        var unique: [CMTime] = []
        for time in times where unique.last.map({ CMTimeCompare($0, time) != 0 }) ?? true { unique.append(time) }
        return unique
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            sha.update(data: data)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard image.width > 0, image.height > 0, max(image.width, image.height) <= 1600,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ExtractionError(message: "Cannot allocate the bounded SDR frame buffer.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExtractionError(message: "Cannot create the extracted JPEG image.")
        }
        CGImageDestinationAddImage(destination, converted, [kCGImageDestinationLossyCompressionQuality: 0.94,
                                                           kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExtractionError(message: "Writing the extracted JPEG failed.") }
    }
}
