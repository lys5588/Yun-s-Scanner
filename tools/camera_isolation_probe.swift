// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
// Standalone diagnostic app source; do not add to the scanner app target.
// Create a separate iOS UIKit app target with NSCameraUsageDescription and use
// this file as its entry point. Requires camera permission on the physical device.
// Reads brightness statistics only; saves no image/video. No ARKit or parameter overrides.
// Status: compiled for a physical device; execution and camera comparison are unverified.
import UIKit
import AVFoundation

@main
final class App: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let probe = Probe()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let label = UILabel(frame: window.bounds.insetBy(dx: 24, dy: 80))
        label.numberOfLines = 0; label.textColor = .white
        label.text = "相机取景诊断\n只读取帧亮度，不保存照片视频。\n请保持 App 在前台。"
        controller.view.addSubview(label)
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        probe.update = { message in DispatchQueue.main.async { label.text = message } }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            if allowed { self?.probe.start() } else { print("PROBE permission denied") }
        }
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) { probe.stop() }
}

final class Probe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "camera-isolation")
    private let session = AVCaptureSession()
    private var devices: [AVCaptureDevice] = []
    private var index = 0
    private var frames = 0
    private var generation = 0
    var update: ((String) -> Void)?
    func start() {
        queue.async { [self] in
            devices = [AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                       AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
                       AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)].compactMap { $0 }
            next()
        }
    }
    func stop() { queue.async { self.generation += 1; self.session.stopRunning() } }
    private func next() {
        session.stopRunning()
        guard index < devices.count else {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            print("PROBE complete; session stopped, inputs/outputs removed")
            update?("诊断完成\n相机已释放。未保存照片或视频。")
            return
        }
        let device = devices[index]; index += 1; frames = 0; generation += 1
        let current = generation
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw NSError(domain: "input", code: 1) }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw NSError(domain: "output", code: 1) }
            session.addOutput(output)
            session.commitConfiguration()
            print("PROBE start \(device.localizedName), position=\(device.position.rawValue); no device parameter overrides")
            update?("检查：\(device.localizedName)\n只读取亮度，不保存图像。")
            session.startRunning()
            queue.asyncAfter(deadline: .now() + 6) { [self] in
                guard generation == current else { return }
                print("PROBE end \(device.localizedName), frames=\(frames), running=\(session.isRunning)")
                next()
            }
        } catch {
            session.commitConfiguration()
            print("PROBE failure \(error)")
            next()
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        guard frames == 30 || frames == 120, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(pixels, 0), h = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var lo = 255, hi = 0, total = 0
        for y in 0..<32 { for x in 0..<32 {
            let v = Int(bytes[(y * h / 32) * stride + x * w / 32])
            lo = min(lo, v); hi = max(hi, v); total += v
        } }
        let device = devices[index - 1]
        print("PROBE \(device.localizedName) frame=\(frames) \(w)x\(h) Ymin=\(lo) Ymax=\(hi) Ymean=\(Double(total)/1024) exposureMode=\(device.exposureMode.rawValue) EV=\(device.exposureTargetBias) ISO=\(device.iso) duration=\(CMTimeGetSeconds(device.exposureDuration)) focusMode=\(device.focusMode.rawValue) WB=\(device.whiteBalanceMode.rawValue)")
    }
}
