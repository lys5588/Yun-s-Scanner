#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
# Reproducible cross-Mac verification. Logs stay under .build/ and no signing is attempted.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
log_root="$root/.build/verification"
mode=all
developer_dir=""
usage() { cat <<'MESSAGE'
用法：bash tools/verify_project.sh [source|mac|ios|all] [--developer-dir PATH]
  source  运行不依赖 Xcode 的项目、语言和 CPU 回归。
  mac     验证并构建 Mac helper/Metal trainer，运行本机 Web 流程测试。
  ios     用完整 Xcode 顺序执行无签名 iPhoneOS 与 iPhoneSimulator Debug build。
  all     依次执行 source、mac、ios。
日志写入 .build/verification/。iOS 27 SDK 只在 ios 模式要求，Mac 模式不要求。
MESSAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    source|--source) mode=source ;; mac|--mac) mode=mac ;; ios|--ios) mode=ios ;; all|--all) mode=all ;;
    --developer-dir) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; developer_dir=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ -z "$developer_dir" || -d "$developer_dir" ]] || { echo "错误：Xcode Developer 目录不存在：$developer_dir" >&2; exit 2; }
[[ -z "$developer_dir" ]] || export DEVELOPER_DIR="$developer_dir"
mkdir -p "$log_root"
run_logged() {
  local name=$1; shift
  local log="$log_root/${name}.log"
  printf '运行：'; printf ' %q' "$@"; printf '\n'
  if "$@" >"$log" 2>&1; then
    cat "$log"; echo "PASS：${name}（日志：${log}）"
  else
    local rc=$?; cat "$log" >&2; echo "失败：${name}（日志：${log}）" >&2; return "$rc"
  fi
}
verify_source() {
  command -v python3 >/dev/null 2>&1 || { echo "错误：source 模式缺少 python3。" >&2; return 1; }
  command -v swiftc >/dev/null 2>&1 || { echo "错误：source 模式缺少 swiftc。" >&2; return 1; }
  run_logged source-project python3 "$root/tools/check_project.py"
  run_logged source-localization bash "$root/tools/test_localization.sh"
  run_logged source-training bash "$root/tools/test_prototype_training.sh"
  run_logged source-model-import verify_model_import
  run_logged source-viewer-math bash "$root/tools/test_gaussian_reality_viewer.sh"
  if [[ -f "$root/TRANSFER_MANIFEST.json" ]]; then
    echo "提示：检测到传输清单。可单独运行 python3 tools/verify_transfer.py；常规源码验证不强制它，以允许本地修改。"
  fi
}
verify_model_import() {
  local output="$root/.build/import-test/test_gaussian_model_import"
  local staged="$output.$$.tmp"
  mkdir -p "$(dirname "$output")" || return $?
  local training="$root/arkit-3dgs-scanner/Training"
  local capture="$root/arkit-3dgs-scanner/Capture"
  swiftc -Onone -module-cache-path "${TMPDIR:-/tmp}/fable-swift-cache" \
    "$capture"/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
    "$root/arkit-3dgs-scanner/History"/{ScanLibrary,GaussianModelImport}.swift "$training"/*.swift \
    "$root/tools/test_gaussian_model_import.swift" -o "$staged" || return $?
  mv -f "$staged" "$output" || return $?
  "$output"
}
verify_mac() {
  run_logged mac-environment bash "$root/tools/check_prototype_environment.sh" --mac
  run_logged mac-preparer bash "$root/tools/build_video_preparer.sh"
  run_logged mac-preparer-self-test "$root/.build/mac-demo/prepare_video_scan" --self-test
  run_logged mac-training bash "$root/tools/build_mac_training.sh"
  [[ -f "$root/.build/mac-demo/supersplat-viewer/public/index.html" ]] || { echo "错误：缺少已构建的 SuperSplat Viewer；先运行 bash tools/setup_project.sh viewer。" >&2; return 1; }
  run_logged mac-demo python3 "$root/tools/test_mac_demo.py"
}
verify_ios() {
  run_logged ios-environment bash "$root/tools/check_prototype_environment.sh" --ios
  local selected_developer
  selected_developer=$(bash "$root/tools/mac_toolchain_fingerprint.sh" developer-dir)
  local common=(env "DEVELOPER_DIR=$selected_developer" xcodebuild -project "$root/arkit-3dgs-scanner.xcodeproj" -scheme arkit-3dgs-scanner -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  run_logged ios-device "${common[@]}" -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$root/.build/DerivedData-ios-device" build
  run_logged ios-simulator "${common[@]}" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$root/.build/DerivedData-ios-simulator" build
}
case "$mode" in
  source) verify_source ;; mac) verify_mac ;; ios) verify_ios ;; all) verify_source; verify_mac; verify_ios ;;
esac
