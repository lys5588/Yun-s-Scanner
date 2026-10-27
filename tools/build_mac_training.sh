#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
# Builds the Mac research CLI and its offline Metal library. It never downloads toolchains.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="$root/.build/mac-demo"
training_dir="$root/arkit-3dgs-scanner/Training"
capture_dir="$root/arkit-3dgs-scanner/Capture"

fail() {
  echo "错误：$*" >&2
  exit 1
}

# Prefer an explicitly selected Xcode, then the active developer directory, then installed apps.
candidates=()
[[ -n "${DEVELOPER_DIR:-}" ]] && candidates+=("$DEVELOPER_DIR")
selected=$(xcode-select -p 2>/dev/null || true)
[[ -n "$selected" ]] && candidates+=("$selected")
[[ -d /Applications/Xcode.app/Contents/Developer ]] && candidates+=(/Applications/Xcode.app/Contents/Developer)
for app in /Applications/Xcode*.app; do
  [[ -d "$app/Contents/Developer" ]] && candidates+=("$app/Contents/Developer")
done

developer_dir=""
metal=""
metallib=""
for candidate in "${candidates[@]}"; do
  [[ -d "$candidate" ]] || continue
  found_metal=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --find metal 2>/dev/null || true)
  found_metallib=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --find metallib 2>/dev/null || true)
  if [[ -n "$found_metal" && -n "$found_metallib" && -x "$found_metal" && -x "$found_metallib" ]]; then
    developer_dir="$candidate"
    metal="$found_metal"
    metallib="$found_metallib"
    break
  fi
done

if [[ -z "$developer_dir" ]]; then
  cat >&2 <<'MESSAGE'
错误：找不到 macOS Metal 编译器。
当前 Command Line Tools 不包含本项目所需的 `metal`/`metallib`，不能构建 Mac 训练器。
请安装与当前 macOS 匹配的完整 Xcode，首次启动并接受许可后安装 Metal Toolchain：
  1. Xcode > Settings > Components > Metal Toolchain > Get
  2. 或：xcodebuild -downloadComponent metalToolchain
然后可选择该 Xcode：
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
重新运行本脚本即可；脚本不会自动下载、安装或切换系统工具链。
MESSAGE
  exit 1
fi

xcode_version=$(DEVELOPER_DIR="$developer_dir" xcodebuild -version 2>/dev/null || true)
[[ -n "$xcode_version" ]] || fail "发现了 Metal 工具，但 Xcode 未完成初始化：$developer_dir。请运行 xcodebuild -runFirstLaunch。"
sdk=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
[[ -d "$sdk" ]] || fail "无法取得 macOS SDK；请检查 Xcode/Metal Toolchain 安装。"
DEVELOPER_DIR="$developer_dir" SDKROOT="$sdk" "$metal" --version >/dev/null 2>&1 || fail "Metal 编译器无法运行：$metal"

[[ -d "$training_dir" && -d "$capture_dir" ]] || fail "未在预期位置找到项目源文件。"
mkdir -p "$build_dir"
staging="$build_dir/.staging-$$"
mkdir "$staging"
trap 'rm -rf "$staging"' EXIT

airs=()
for source in "$training_dir"/*.metal; do
  [[ -f "$source" ]] || fail "未找到 Metal 源文件。"
  air="$staging/$(basename "${source%.metal}").air"
  DEVELOPER_DIR="$developer_dir" SDKROOT="$sdk" "$metal" -std=metal3.1 -ffast-math -c "$source" -o "$air"
  airs+=("$air")
done
DEVELOPER_DIR="$developer_dir" SDKROOT="$sdk" "$metallib" "${airs[@]}" -o "$staging/gs.metallib"

capture_sources=(
  "$capture_dir/Localization.swift"
  "$capture_dir/Models.swift"
  "$capture_dir/BlurFilter.swift"
  "$capture_dir/CaptureConfig.swift"
  "$capture_dir/DepthSampleFilter.swift"
  "$capture_dir/RefusionEngine.swift"
  "$capture_dir/SurfaceTSDF.swift"
  "$capture_dir/ExportManager.swift"
  "$capture_dir/TrainingFrameSelector.swift"
)
training_sources=("$training_dir"/*.swift)
for source in "${capture_sources[@]}" "${training_sources[@]}"; do
  [[ -f "$source" ]] || fail "缺少 Swift 源文件：$source"
done

DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx swiftc -O \
  -module-cache-path "${TMPDIR:-/tmp}/arkit-3dgs-swift-cache" \
  "${capture_sources[@]}" "$root/arkit-3dgs-scanner/History/ScanLibrary.swift" "$root/arkit-3dgs-scanner/History/GaussianModelImport.swift" \
  "${training_sources[@]}" "$root/tools/train_gaussians.swift" \
  -o "$staging/train_gaussians"

# Each output is fully built before its same-filesystem rename; a failed build leaves prior outputs intact.
mv -f "$staging/gs.metallib" "$build_dir/gs.metallib"
mv -f "$staging/train_gaussians" "$build_dir/train_gaussians"
DEVELOPER_DIR="$developer_dir" bash "$root/tools/mac_toolchain_fingerprint.sh" training > "$build_dir/training.fingerprint.$$.staging"
mv -f "$build_dir/training.fingerprint.$$.staging" "$build_dir/training.fingerprint"
echo "构建完成："
echo "  Xcode: $developer_dir"
echo "  SDK: $sdk"
echo "  CLI: $build_dir/train_gaussians"
echo "  Metal: $build_dir/gs.metallib"
