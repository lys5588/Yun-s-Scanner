// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers

/// The Photos picker grants access only to the chosen movie. Copy before its provider URL expires.
nonisolated struct PickedVideo: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("picked-video-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                let target = directory.appendingPathComponent(received.file.lastPathComponent)
                let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 else { throw VideoImportError.invalidVideo }
                guard size <= 2_000_000_000 else { throw VideoImportError.tooLarge }
                let input = try FileHandle(forReadingFrom: received.file)
                defer { try? input.close() }
                guard fm.createFile(atPath: target.path, contents: nil) else { throw VideoImportError.insufficientStorage }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                while true {
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
                    try output.write(contentsOf: data)
                }
                try output.synchronize()
                try Task.checkCancellation()
                return PickedVideo(url: target)
            } catch {
                try? fm.removeItem(at: directory)
                throw error
            }
        }
    }
}

struct VideoImportView: View {
    var onLibraryChange: () -> Void = {}
    let isBeta: Bool
    @StateObject private var model: VideoImportCoordinator
    init(isBeta: Bool = false, onLibraryChange: @escaping () -> Void = {}) {
        self.isBeta = isBeta
        self.onLibraryChange = onLibraryChange
        _model = StateObject(wrappedValue: VideoImportCoordinator(isBeta: isBeta))
    }
    @ObservedObject private var training = TrainingCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var photoTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var poster: CGImage?
    @State private var playingPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(isBeta ? L10n.text("导入视频，整理采集数据") : L10n.text("把已有影片變成 3D 模型"))
                        .font(.title2.bold())
                    Text(isBeta ? L10n.text("在设备上抽帧并估计相机位姿，预览后保存场景 ZIP。") : L10n.text("選擇照片或檔案中的影片，在 iPhone 上抽取影格、估計相機，再訓練與查看 3DGS 模型。影片不會上傳。"))
                        .font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                    Text(L10n.text("建議 30–60 秒、靜態場景、緩慢移動拍攝；最長 3 分鐘。"))
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                }

                VStack(spacing: DS.Space.s) {
                    PhotosPicker(selection: $photoItem, matching: .videos, preferredItemEncoding: .current) {
                        Label(L10n.text("從照片選擇影片"), systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(DSPrimaryButtonStyle(tint: isBeta ? .orange : DS.Palette.accent))
                    .accessibilityIdentifier("chooseVideoFromPhotos")
                    Button { showFiles = true } label: {
                        Label(L10n.text("從檔案選擇影片"), systemImage: "folder")
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("chooseVideoFromFiles")
                }
                .disabled(model.isBusy || loadingPhoto)

                if loadingPhoto {
                    ProgressView(L10n.text("正在載入所選影片…"))
                }

                if let selected = model.selection {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        if let player {
                            ZStack {
                                Color.black
                                if let poster, !playingPreview {
                                    Image(decorative: poster, scale: 1).resizable().scaledToFit()
                                        .accessibilityIdentifier("selectedVideoPoster")
                                    Button {
                                        playingPreview = true
                                        player.play()
                                    } label: {
                                        Label(L10n.text("播放影片"), systemImage: "play.fill")
                                            .padding(12).background(.ultraThinMaterial, in: Capsule())
                                    }
                                    .accessibilityIdentifier("playSelectedVideo")
                                } else {
                                    VideoPreviewPlayer(player: player)
                                }
                            }
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
                            .accessibilityIdentifier("selectedVideoPreview")
                        }
                        Text(selected.name).font(.headline).lineLimit(2)
                            .accessibilityIdentifier("selectedVideoName")
                        Text(L10n.text("\(Int(selected.duration.rounded())) 秒・\(ByteCountFormatter.string(fromByteCount: selected.bytes, countStyle: .file))"))
                            .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    .dsCard(padding: DS.Space.m)
                }

                if model.isBusy {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text(model.stageTitle).font(.headline)
                        if model.phase == .copying || model.phase == .publishing {
                            ProgressView()
                        } else {
                            ProgressView(value: model.progress)
                            Text(L10n.text("\(Int(model.progress * 100))%"))
                                .font(.caption.monospacedDigit())
                        }
                        Text(model.backgroundStatus.isEmpty ? L10n.text("正在准备处理，请保持前台。") : model.backgroundStatus)
                            .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                        Button(L10n.text("取消處理")) { model.cancel() }
                            .accessibilityIdentifier("cancelVideoPreparation")
                    }
                    .tint(DS.Palette.accent)
                    .dsCard(padding: DS.Space.m)
                    .accessibilityIdentifier("videoPreparationProgress")
                }

                if !model.isSupported {
                    Label(model.unsupportedMessage, systemImage: "info.circle")
                        .font(.subheadline).foregroundStyle(DS.Palette.warning)
                        .accessibilityIdentifier("videoReconstructionUnavailable")
                }
                if training.isBusy {
                    Text(L10n.text("另一筆掃描正在訓練，完成或停止後才能開始"))
                        .font(.subheadline).foregroundStyle(DS.Palette.warning)
                }
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(DS.Palette.warning)
                        .accessibilityIdentifier("videoImportMessage")
                }
                Text(L10n.text("普通影片沒有 LiDAR 深度或已知公制尺度，重建結果不提供公尺量測。"))
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: DS.Size.panelMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .dsCanvas()
        .navigationTitle(L10n.text("使用已有影片"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                player?.pause()
                model.prepare(onPublished: onLibraryChange)
            } label: {
                Label(isBeta ? L10n.text("计算位姿并预览") : L10n.text("在 iPhone 上準備重建"), systemImage: "cube.transparent")
            }
            .buttonStyle(DSPrimaryButtonStyle(tint: isBeta ? .orange : DS.Palette.accent))
            .disabled(model.selection == nil || model.isBusy || loadingPhoto || !model.isSupported || training.isBusy)
            .accessibilityIdentifier("prepareVideoReconstruction")
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
            .background(DS.Palette.canvas)
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first, scenePhase == .active { player?.pause(); model.select(url) }
            case .failure(let error): model.message = VideoImportError.display(error)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadingPhoto = true
            player?.pause()
            photoTask = Task {
                defer { loadingPhoto = false; photoTask = nil; photoItem = nil }
                do {
                    guard let picked = try await item.loadTransferable(type: PickedVideo.self) else { throw VideoImportError.invalidVideo }
                    guard !Task.isCancelled, scenePhase == .active else {
                        try? FileManager.default.removeItem(at: picked.url.deletingLastPathComponent())
                        return
                    }
                    model.select(picked.url, removeAfterCopy: true)
                } catch {
                    if !Task.isCancelled { model.message = VideoImportError.display(error) }
                }
            }
        }
        .task(id: model.selection?.url) {
            player?.pause()
            player = nil
            poster = nil
            playingPreview = false
            guard let url = model.selection?.url else { return }
            let asset = AVURLAsset(url: url)
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            if #available(iOS 18.0, *) { generator.dynamicRangePolicy = .forceSDR }
            do {
                // A real SDR poster avoids Simulator's HDR player clipping. Playback still
                // uses the original movie; this never becomes a reconstruction input.
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let start = try await tracks.first?.load(.timeRange).start ?? .zero
                let result = try await withTaskCancellationHandler {
                    try await generator.image(at: start)
                } onCancel: { generator.cancelAllCGImageGeneration() }
                try Task.checkCancellation()
                if model.selection?.url == url { poster = result.image }
            } catch {
                if !Task.isCancelled { model.message = VideoImportError.display(error) }
            }
        }
        .navigationDestination(item: $model.preparedScan) { scan in
            if isBeta { BetaSceneView(directory: scan) }
            else { GaussianTrainingView(scan: scan, onLibraryChange: onLibraryChange) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                player?.pause()
                photoTask?.cancel()
                model.sceneActivityChanged(isActive: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            if ProcessInfo.processInfo.thermalState == .critical { model.cancel() }
        }
        .onDisappear {
            player?.pause()
            photoTask?.cancel()
            model.leave()
        }
    }
}

/// Native playback of the unchanged original movie. The separately generated poster is SDR.
private struct VideoPreviewPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        if #available(iOS 26.0, *) { controller.preferredDisplayDynamicRange = .standard }
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
