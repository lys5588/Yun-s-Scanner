// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import SwiftUI
import AVKit

struct BetaSceneView: View {
    let directory: URL
    @State private var entry: ScanEntry?
    @State private var preview: ScanPreview?
    @State private var includeLiDAR = false
    @State private var display = false
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var saving = false
    @State private var archive: URL?
    @State private var reset = 0
    @State private var renaming = false
    @State private var showMap = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(display ? "02 / VISUALIZATION" : "01 / PREVIEW", systemImage: display ? "point.3.connected.trianglepath.dotted" : "play.rectangle")
                    .font(.caption.monospaced().weight(.semibold)).foregroundStyle(.orange)
                if let entry {
                    Button { renaming = true } label: {
                        HStack {
                            Text(entry.displayName).font(.title2.bold()).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "pencil").font(.body)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(saving).accessibilityIdentifier("betaRenameScene")
                    Text(entry.date.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if let location = entry.location {
                        Button { showMap = true } label: {
                            HStack {
                                Image(systemName: "mappin.and.ellipse")
                                Text(location.address ?? String(format: "%.5f, %.5f", location.latitude, location.longitude)).lineLimit(2)
                                Spacer()
                                Image(systemName: "map")
                            }.font(.subheadline).padding(16)
                                .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityIdentifier("betaOpenMap")
                    } else {
                        Label(L10n.text("此场景未记录拍摄位置。"), systemImage: "location.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let preview {
                    if display {
                        ReviewPointCloudView(points: includeLiDAR || entry?.isVideoImport == true ? preview.points : [],
                                             trajectory: preview.trajectory, resetCameraToken: reset)
                            .id(includeLiDAR).frame(height: 340).clipShape(RoundedRectangle(cornerRadius: 22))
                        HStack {
                            Text(L10n.text("拖动旋转 · 双指缩放")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { reset += 1 } label: { Image(systemName: "scope") }
                                .accessibilityLabel(L10n.text("顯示完整點雲"))
                        }
                    } else if let player {
                        VideoPlayer(player: player).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                    HStack(spacing: 22) {
                        metric("\(preview.images.count)", L10n.text("帧"))
                        metric("\(preview.trajectory.count)", L10n.text("相机位姿"))
                        metric(entry?.isVideoImport == true ? "SfM" : "ARKit", L10n.text("轨迹来源"))
                    }.frame(maxWidth: .infinity).padding(18)
                        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
                    Toggle(isOn: $includeLiDAR) {
                        Label(L10n.text("使用 LiDAR"), systemImage: "sensor.tag.radiowaves.forward")
                    }.disabled(entry?.usedLiDAR != true || saving).tint(.orange)
                        .accessibilityIdentifier("betaPreviewLiDAR")
                    Text(entry?.usedLiDAR == true
                         ? L10n.text("开启后显示点云，并将采集深度一起保存。")
                         : L10n.text("此场景未采集 LiDAR，保存视频、影像和位姿。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if entry?.isVideoImport == true {
                        Text(L10n.text("普通视频的估计轨迹为相对尺度，不提供米制距离。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice = preview.processingNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("场景数据包")).font(.headline)
                        Label(L10n.text("原始视频"), systemImage: "film")
                        Label(L10n.text("逐帧图像与相机位姿"), systemImage: "photo.stack")
                        if includeLiDAR { Label(L10n.text("LiDAR 深度与置信度"), systemImage: "square.3.layers.3d") }
                        Text("ZIP · JPEG · JSONL" + (includeLiDAR ? " · F32 / U8" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
                } else if error == nil { ProgressView(L10n.text("正在载入场景…")).frame(maxWidth: .infinity).padding(80) }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.subheadline) }
                if let archive {
                    Text(archive.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Button { SystemShare.present([archive]) } label: { Label(L10n.text("导出到文件 / 分享"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(DSSecondaryButtonStyle()).accessibilityIdentifier("betaShareZIP")
                }
                if entry != nil {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(L10n.text("删除场景"), systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.disabled(saving).accessibilityIdentifier("betaDeleteScene")
                }
            }.padding(24)
        }.dsCanvas().navigationTitle(display ? "Visualization" : L10n.text("场景预览"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(saving)
            .sheet(isPresented: $renaming) {
                if let entry { BetaRenameSheet(entry: entry) { Task { await refreshEntry(); archive = nil } } }
            }
            .sheet(isPresented: $showMap) {
                if let entry, let location = entry.location { BetaSceneMap(location: location, name: entry.displayName) }
            }
            .alert(L10n.text("删除这个场景？"), isPresented: $confirmDelete) {
                Button(L10n.text("删除"), role: .destructive) { deleteScene() }
                Button(L10n.text("取消"), role: .cancel) { }
            } message: { Text(L10n.text("将删除场景及原始采集数据；此前导出的 ZIP 会保留。")) }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if archive != nil {
                        Label(L10n.text("场景 ZIP 已保存"), systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green).accessibilityIdentifier("betaSaved")
                    }
                    Button {
                        if let archive { SystemShare.present([archive]) }
                        else if display { save() }
                        else { player?.pause(); display = true }
                    } label: {
                        if saving { ProgressView().tint(.white) }
                        else if archive != nil { Label(L10n.text("导出到文件 / 分享"), systemImage: "square.and.arrow.up") }
                        else { Label(display ? L10n.text("保存场景 ZIP") : L10n.text("进入 Visualization"), systemImage: display ? "square.and.arrow.down" : "cube.transparent") }
                    }.buttonStyle(DSPrimaryButtonStyle(tint: .orange)).disabled(preview == nil || saving)
                        .accessibilityIdentifier(display ? "betaSaveZIP" : "betaVisualize")
                }.padding(.horizontal, 24).padding(.vertical, 12).background(DS.Palette.canvas)
            }
            .onChange(of: includeLiDAR) { _, _ in archive = nil }
            .task(id: directory) { await load() }
            .onDisappear { player?.pause() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
    }
    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func load() async {
        do {
            let found = try await ScanLibrary.beta.entry(at: directory)
            entry = found
            includeLiDAR = found.usedLiDAR == true
            preview = try await ScanLibrary.beta.preview(found)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if let movie = files.first(where: { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }) {
                player = AVPlayer(url: movie)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        saving = true; error = nil
        let useDepth = includeLiDAR
        Task {
            defer { saving = false }
            do { archive = try await BetaSceneArchive.shared.save(directory: directory, includeLiDAR: useDepth) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func refreshEntry() async {
        do { entry = try await ScanLibrary.beta.entry(at: directory) }
        catch { self.error = error.localizedDescription }
    }
    private func deleteScene() {
        guard let entry else { return }
        saving = true; player?.pause()
        Task {
            defer { saving = false }
            do {
                try await ScanLibrary.beta.delete(entry)
                NotificationCenter.default.post(name: .betaLibraryChanged, object: nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
