#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/local-data/inbox" "$root/local-data/runs"
for command in python3 ffmpeg ffprobe swiftc; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf '缺少命令：%s。请按 README 安装本机调试依赖。\n' "$command" >&2
    exit 1
  fi
done
helper="$root/.build/mac-demo/prepare_video_scan"
stamp="$root/.build/mac-demo/prepare_video_scan.fingerprint"
current_stamp=""
if current_stamp=$(bash "$root/tools/mac_toolchain_fingerprint.sh" preparer 2>/dev/null); then :; else
  echo "错误：无法确定当前 Mac 的摄影测量工具链；不能使用可能来自其他主机的 helper。" >&2
  exit 1
fi
if [[ ! -x "$helper" || ! -f "$stamp" || "$root/tools/prepare_video_scan.swift" -nt "$helper" || "$root/tools/build_video_preparer.sh" -nt "$helper" || "$(cat "$stamp")" != "$current_stamp" ]]; then
  bash "$root/tools/build_video_preparer.sh"
fi
if [[ ! -f "$root/.build/mac-demo/supersplat-viewer/public/index.html" ]]; then
  bash "$root/tools/setup_mac_viewer.sh"
fi
exec python3 "$root/tools/mac_demo.py" "$@"
