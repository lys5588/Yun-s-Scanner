// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
// Compile with the app's VideoFrameExtractor.swift to exercise the same extraction
// implementation on a supplied real video or independently encoded timing fixture.

import Foundation
import ImageIO

@main struct VideoFrameExtractorCheck {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let cancel = arguments.first == "--cancel"
        if cancel { arguments.removeFirst() }
        guard arguments.count == 2 || arguments.count == 3 else {
            throw NSError(domain: "VideoFrameExtractorCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "usage: test-video-frame-extractor [--cancel] SOURCE_MOVIE NEW_OUTPUT_DIRECTORY [MAX_FRAMES]"])
        }
        let source = URL(fileURLWithPath: arguments[0])
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "VideoFrameExtractorCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Output must not already exist"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let limit = arguments.count == 3 ? Int(arguments[2]) ?? 200 : 200
        let (updates, continuation) = AsyncStream.makeStream(of: Double.self)
        let extraction = Task {
            defer { continuation.finish() }
            return try await VideoFrameExtractor.extract(sourceURL: source, scanDirectory: directory,
                                                          maximumFrames: limit) { continuation.yield($0) }
        }
        if cancel {
            for await value in updates where value >= 0.15 {
                extraction.cancel()
                break
            }
            do {
                _ = try await extraction.value
                fatalError("Cancellation unexpectedly published an extraction")
            } catch {
                precondition(extraction.isCancelled)
                for name in ["images", "video-frames.json", "video-source.json"] {
                    precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
                }
                let finalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
                precondition((originalAttributes[.size] as? NSNumber) == (finalAttributes[.size] as? NSNumber))
                precondition((originalAttributes[.modificationDate] as? Date) == (finalAttributes[.modificationDate] as? Date))
                print("PASS: cancellation during real extraction removed partial images/metadata and preserved the source movie")
                return
            }
        }
        let result = try await extraction.value
        let timeline = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("video-frames.json"))) as! [[String: Any]]
        precondition(timeline.count == result.frameCount && result.frameCount >= 8)
        var previous: Double?
        for frame in timeline {
            let timestamp = (frame["timestamp"] as! NSNumber).doubleValue
            precondition(timestamp.isFinite && (previous.map { timestamp - $0 >= 0.499999 } ?? true))
            previous = timestamp
            let url = directory.appendingPathComponent("images").appendingPathComponent(frame["imageFile"] as! String)
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
                fatalError("Cannot decode extracted JPEG")
            }
            precondition(max(image.width, image.height) <= 1600 && image.bitsPerComponent == 8)
            // ImageIO may omit the default orientation tag; absent EXIF means up.
            precondition(((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1)
            precondition(image.colorSpace?.name == CGColorSpace.sRGB)
        }
        print("PASS: \(result.frameCount) actual-PTS, upright sRGB 8-bit JPEG frames; duration=\(result.duration)")
    }
}
