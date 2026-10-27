// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import SwiftUI

/// Choose the geometry source before requesting the camera or creating an AR session.
struct CapturePreparationView: View {
    @Binding var mode: CaptureMode
    let supportsLiDAR: Bool
    let canScan: Bool
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Text(L10n.text("选择重建方式"))
                        .font(.title2.bold())
                    Text(L10n.text("两种方式都会保存拍摄视频和相机位姿，并在 iPhone 上完成 3DGS 重建。"))
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                    CaptureModePicker(mode: $mode, supportsLiDAR: supportsLiDAR)
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Label(L10n.text("默认画质"), systemImage: "video")
                            .font(.headline)
                        Text(L10n.text("优先使用 1080p / 30 fps；实际分辨率和帧率取决于设备支持。"))
                            .font(.subheadline)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(padding: DS.Space.m)
                    Label(L10n.text("拍摄时请保持 App 在前台，缓慢移动，让同一物体出现在多个视角中。"), systemImage: "figure.walk")
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                    if !canScan {
                        Label(L10n.text("此裝置不支援 AR 掃描"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(DS.Palette.warning)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Space.l)
                .frame(maxWidth: DS.Size.panelMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .dsCanvas()
            .navigationTitle(L10n.text("拍摄准备"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onContinue) {
                    Label(L10n.text("进入相机"), systemImage: "camera")
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(!canScan || (mode == .lidar && !supportsLiDAR))
                .accessibilityIdentifier("continueToCapture")
                .frame(maxWidth: DS.Size.panelMaxWidth)
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity)
                .background(DS.Palette.canvas)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.Palette.canvas)
        .presentationCornerRadius(DS.Radius.xl)
    }
}

/// The same two choices are visible in preparation and in the camera's pre-scan settings.
struct CaptureModePicker: View {
    @Binding var mode: CaptureMode
    let supportsLiDAR: Bool

    var body: some View {
        VStack(spacing: DS.Space.s) {
            option(.camera)
            option(.lidar)
        }
    }

    private func option(_ option: CaptureMode) -> some View {
        let available = option == .camera || supportsLiDAR
        let selected = mode == option
        return Button { mode = option } label: {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: option == .lidar ? "sensor.tag.radiowaves.forward" : "camera")
                    .font(.title3)
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(option == .lidar ? L10n.text("相机 + LiDAR") : L10n.text("仅相机"))
                        .font(.headline)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(option == .lidar
                         ? L10n.text("使用同步的 LiDAR 深度融合点云，再结合图像重建模型。")
                         : L10n.text("不使用 LiDAR，通过多视角图像和 ARKit 位姿重建点云与模型。"))
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                    if !available {
                        Text(L10n.text("此设备不支持 LiDAR，可使用仅相机方式。"))
                            .font(.caption)
                            .foregroundStyle(DS.Palette.warning)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(padding: DS.Space.m)
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(selected ? DS.Palette.accent : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.6)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(option == .lidar ? "captureModeLiDAR" : "captureModeCamera")
    }
}
