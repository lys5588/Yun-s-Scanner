#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
# Read-only prerequisite check. It never installs software, changes xcode-select, accepts a licence, or reboots.
set -euo pipefail

mode=all
case "${1:-}" in
  ""|all|--all) ;;
  mac|--mac) mode=mac ;;
  ios|--ios) mode=ios ;;
  -h|--help)
    cat <<'MESSAGE'
用法：bash tools/check_prototype_environment.sh [--mac|--ios|--all]
  --mac  检查 Mac 摄影测量、Metal 训练器所需的完整 Xcode 与 Metal Toolchain。
  --ios  检查 iOS 27 原生查看器所需的 iOS 27 SDK；不要求 Mac 运行 iOS 27。
MESSAGE
    exit 0 ;;
  *) echo "错误：未知模式：$1" >&2; exit 2 ;;
esac

issues=0
fail() { printf '需要处理：%s\n' "$*" >&2; issues=$((issues + 1)); }
command -v xcode-select >/dev/null 2>&1 || fail "找不到 xcode-select；需要完整 Xcode。"

candidates=()
[[ -n "${DEVELOPER_DIR:-}" ]] && candidates+=("$DEVELOPER_DIR")
selected=$(xcode-select -p 2>/dev/null || true)
[[ -n "$selected" ]] && candidates+=("$selected")
[[ -d /Applications/Xcode.app/Contents/Developer ]] && candidates+=(/Applications/Xcode.app/Contents/Developer)
for app in /Applications/Xcode*.app; do
  [[ -d "$app/Contents/Developer" ]] && candidates+=("$app/Contents/Developer")
done

developer_dir=""
initialized_developer_dir=""
for candidate in "${candidates[@]}"; do
  [[ -d "$candidate" ]] || continue
  DEVELOPER_DIR="$candidate" xcodebuild -version >/dev/null 2>&1 || continue
  [[ -n "$initialized_developer_dir" ]] || initialized_developer_dir="$candidate"
  if [[ "$mode" == mac || "$mode" == all ]]; then
    metal=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --find metal 2>/dev/null || true)
    metallib=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --find metallib 2>/dev/null || true)
    [[ -n "$metal" && -x "$metal" && -n "$metallib" && -x "$metallib" ]] || continue
  fi
  developer_dir="$candidate"
  break
done
# Preserve an initialized Xcode for precise SDK/Metal diagnostics below, even when
# none of the installed Xcodes has both optional Metal tools yet.
[[ -n "$developer_dir" ]] || developer_dir="$initialized_developer_dir"
if [[ -z "$developer_dir" ]]; then
  fail "找不到已完成首次启动的完整 Xcode；Command Line Tools 只能运行 source 模式。"
else
  version=$(DEVELOPER_DIR="$developer_dir" xcodebuild -version | tr '\n' ' ')
  printf '选定 Xcode：%s（%s）\n' "$developer_dir" "$version"
fi

if [[ "$mode" == mac || "$mode" == all ]]; then
  if [[ -n "$developer_dir" ]]; then
    DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || fail "该 Xcode 缺少 macOS SDK。"
    DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx metal --version >/dev/null 2>&1 || fail "该 Xcode 的 Metal Toolchain 缺失或无法运行；在 Xcode > Settings > Components 安装，或运行 xcodebuild -downloadComponent MetalToolchain。"
    DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx metallib --version >/dev/null 2>&1 || fail "该 Xcode 的 metallib 缺失或无法运行。"
  fi
fi
if [[ "$mode" == ios || "$mode" == all ]]; then
  if [[ -n "$developer_dir" ]]; then
    ios_sdk=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)
    sim_sdk=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true)
    [[ -n "$ios_sdk" ]] || fail "该 Xcode 缺少 iPhoneOS SDK。"
    [[ -n "$sim_sdk" ]] || fail "该 Xcode 缺少 iPhoneSimulator SDK。"
    ios_major=${ios_sdk%%.*}
    [[ "$ios_major" =~ ^[0-9]+$ ]] && (( ios_major >= 27 )) || fail "原生高斯查看器需要 iOS 27 SDK；当前为 ${ios_sdk:-未安装}。"
  fi
fi

if (( issues > 0 )); then
  printf '环境检查失败：%d 项依赖未满足。脚本没有安装、下载或修改系统设置。\n' "$issues" >&2
  exit 1
fi
printf 'PASS：%s 模式依赖满足。\n' "$mode"
