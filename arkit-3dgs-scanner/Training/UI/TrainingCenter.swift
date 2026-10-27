// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import SwiftUI
import UIKit
import Combine
import BackgroundTasks

/// A Bool shared between the main thread and the training thread.
nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// App-wide owner of the single training run. Background GPU use requires both device
/// support and an actual continued-processing grant; otherwise checkpoint and pause.
@MainActor
final class TrainingCenter: ObservableObject {
    static let shared = TrainingCenter()

    @Published private(set) var activeScan: URL?
    @Published private(set) var configuration: GaussianTrainingConfiguration?
    @Published private(set) var snapshot = TrainingSnapshot()
    @Published private(set) var frame: CGImage?
    @Published private(set) var frameRequest: ViewerRequest?
    @Published private(set) var views: [TrainingFrame] = []
    @Published private(set) var initialDepth = 1.5
    /// Bumped whenever a run ends so History re-reads training states.
    @Published private(set) var revision = 0
    /// Training keeps running when the app leaves the foreground (a continued-processing task
    /// with background GPU access is active, iOS 26+); otherwise it pauses with a checkpoint.
    @Published private(set) var continuesInBackground = false
    @Published private(set) var backgroundStatus = ""
    private var processingLease: ContinuedProcessingLease?
    /// A capture is on screen; training pauses meanwhile.
    private var capturing = false

    private var session: GaussianTrainingSession?
    private var observers: [NSObjectProtocol] = []
    /// Battery state read on main (UIDevice is main-thread only) for the training thread.
    private let batteryLow = LockedFlag()
    private var memorySource: DispatchSourceMemoryPressure?

    private init() {
        let center = NotificationCenter.default
        // Pause as soon as the app stops being active: GPU work is still allowed then, so the
        // pause checkpoint can be written; a background task covers the file write.
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaveForeground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaveForeground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session?.setAppInBackground(false)
                self?.session?.setBackgrounded(false)
                self?.endBackgroundTask()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.memoryPressure(critical: false) }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.memorySource else { return }
                self.session?.memoryPressure(critical: source.data.contains(.critical))
            }
        }
        source.resume()
        memorySource = source
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBattery() }
            })
        }
        updateBattery()
    }

    private func updateBattery() {
        let device = UIDevice.current
        batteryLow.value = device.batteryState == .unplugged && device.batteryLevel >= 0 && device.batteryLevel < 0.15
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func leaveForeground() {
        guard let session else { return }
        if continuesInBackground {
            // The system granted background GPU time: keep training, without live previews.
            session.setAppInBackground(true)
            return
        }
        session.setBackgrounded(true)
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "gaussian-checkpoint") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func isActive(_ scan: URL) -> Bool { activeScan?.standardizedFileURL.path == scan.standardizedFileURL.path }
    var isBusy: Bool { activeScan != nil }

    /// Starts (or resumes from the checkpoint) training of `scan`. Returns false if another scan
    /// is training.
    @discardableResult
    func start(scan: URL, configuration: GaussianTrainingConfiguration, resume: Bool) -> Bool {
        guard !VideoImportCoordinator.isPreparing else { return false }
        guard activeScan == nil || isActive(scan) else { return false }
        guard session == nil else { return true }
        let session = GaussianTrainingSession(workspace: TrainingWorkspace(scan: scan), configuration: configuration, resume: resume)
        session.thermalLevel = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return 0
            case .fair: return 1
            case .serious: return 2
            case .critical: return 3
            @unknown default: return 2
            }
        }
        let battery = batteryLow
        session.batteryLow = { battery.value }
        session.lowPowerMode = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        session.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async { self?.receive(snapshot) }
        }
        session.onFrame = { [weak self] frame, request in
            let image = frame.cgImage
            DispatchQueue.main.async { self?.frame = image; self?.frameRequest = request }
        }
        session.onPreparedViews = { [weak self] views, depth in
            DispatchQueue.main.async { self?.views = views; self?.initialDepth = depth }
        }
        self.session = session
        activeScan = scan
        self.configuration = configuration
        snapshot = TrainingSnapshot(phase: .preparing, iteration: configuration.startIteration, total: configuration.iterations,
                                    startIteration: configuration.startIteration)
        frame = nil
        views = []
        UIApplication.shared.isIdleTimerDisabled = true
        session.setCapturing(capturing)
        beginContinuedProcessing()
        let thread = Thread { session.run() }
        thread.name = "gaussian-training"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
        return true
    }

    private func receive(_ snapshot: TrainingSnapshot) {
        self.snapshot = snapshot
        reportContinuedProgress(snapshot)
        // Speeds come from full new runs: early finishes and enhancements train a different mix.
        if snapshot.phase == .completed, let configuration, !configuration.isEnhancement,
           snapshot.total > 0, snapshot.iteration >= snapshot.total {
            TrainingSpeedHistory.record(configuration, secondsPerIteration: snapshot.elapsedSeconds / Double(snapshot.total))
        }
        switch snapshot.phase {
        case .completed, .failed, .cancelled:
            session = nil
            activeScan = nil
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
            revision += 1
        case .paused:
            UIApplication.shared.isIdleTimerDisabled = false
            // The pause checkpoint is on disk; the background grace period is no longer needed.
            endBackgroundTask()
            processingLease?.finish(success: false)
            processingLease = nil
            backgroundStatus = L10n.text("可以在 App 內切換頁面；切到其他 App 時會先暫停並儲存進度")
        default:
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    /// Pauses training while a capture is open (and resumes when it closes).
    func setCapturing(_ value: Bool) {
        capturing = value
        session?.setCapturing(value)
    }

    func pause() { session?.pause() }
    func resume() {
        session?.resumeTraining()
        // Resuming is a user action, so background time can be requested again after it expired.
        if session != nil, processingLease == nil { beginContinuedProcessing() }
    }
    func checkpoint() { session?.saveCheckpoint() }
    func finishNow() { session?.finishNow() }
    func cancel(keepCheckpoint: Bool) { session?.cancel(keepCheckpoint: keepCheckpoint) }
    func updateViewer(_ request: ViewerRequest?, interactive: Bool) { session?.updateViewer(request, interactive: interactive) }

    // MARK: Background continuation

    private func beginContinuedProcessing() {
        guard processingLease == nil else { return }
        let lease = ContinuedProcessingLease(title: L10n.text("訓練 3DGS"), requiresGPU: true,
            onExpiration: { [weak self] in
                guard let self else { return }
                // System cancellation applies even while this app is still in the foreground.
                self.session?.pause()
                if UIApplication.shared.applicationState != .active { self.leaveForeground() }
            }, onChange: { [weak self] in
                guard let self else { return }
                self.continuesInBackground = self.processingLease?.isGranted == true
                self.backgroundStatus = self.processingLease?.status ?? ""
                if self.continuesInBackground, UIApplication.shared.applicationState != .active {
                    self.session?.setAppInBackground(true)
                    self.session?.setBackgrounded(false)
                }
            })
        processingLease = lease
        lease.begin()
    }

    private func reportContinuedProgress(_ snapshot: TrainingSnapshot) {
        let fraction: Double
        switch snapshot.phase {
        case .preparing: fraction = 0.10 * snapshot.preparationProgress
        case .finishing:
            fraction = 0.90 + 0.09 * Double(snapshot.saving.map(TrainingPresentation.savingPercent) ?? 0) / 100
        default:
            let count = max(1, snapshot.total - snapshot.startIteration)
            fraction = 0.10 + 0.80 * Double(max(0, snapshot.iteration - snapshot.startIteration)) / Double(count)
        }
        processingLease?.report(fraction: fraction, subtitle: TrainingPresentation.stage(snapshot))
        switch snapshot.phase {
        case .completed, .failed, .cancelled:
            processingLease?.finish(success: snapshot.phase == .completed)
            processingLease = nil
        default: break
        }
    }
}
