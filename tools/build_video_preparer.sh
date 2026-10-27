#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/.build/mac-demo/prepare_video_scan"
stamp="$root/.build/mac-demo/prepare_video_scan.fingerprint"
mkdir -p "$(dirname -- "$out")"
developer_dir=$(bash "$root/tools/mac_toolchain_fingerprint.sh" preparer-dir)
swiftc_path=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --find swiftc 2>/dev/null || true)
[[ -n "$swiftc_path" && -x "$swiftc_path" ]] || { echo "错误：找不到 Swift 编译器。请安装或选择完整 Xcode。" >&2; exit 1; }
staging="$out.$$.staging"
trap 'rm -f "$staging"' EXIT
DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx swiftc -parse-as-library -O -framework Foundation -framework RealityKit -framework ImageIO -framework CoreGraphics \
  "$root/tools/prepare_video_scan.swift" -o "$staging"
mv -f "$staging" "$out"
DEVELOPER_DIR="$developer_dir" bash "$root/tools/mac_toolchain_fingerprint.sh" preparer > "$stamp.$$.staging"
mv -f "$stamp.$$.staging" "$stamp"
trap - EXIT
printf '%s\n' "$out"
