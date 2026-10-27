#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
# Cross-Mac setup entry point. It only checks dependencies and builds project-owned outputs.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=all
developer_dir=""
usage() { cat <<'MESSAGE'
用法：bash tools/setup_project.sh [source|mac|viewer|all] [--developer-dir PATH]
  --source  检查可运行纯源码验证的 python3、swiftc、git，不需要 Xcode。
  --mac     构建 Mac 摄影测量 helper 和 Metal 训练器，需要完整 Xcode 与 Metal Toolchain。
  --viewer  构建固定版本的 SuperSplat Web 查看器，需要 git、Node.js 20+ 与网络。
  --all     依次执行 source、mac、viewer。
`--developer-dir` 仅为本次命令选择已安装的 Xcode，不会修改 xcode-select。
MESSAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    source|--source) mode=source ;; mac|--mac) mode=mac ;; viewer|--viewer) mode=viewer ;; all|--all) mode=all ;;
    --developer-dir) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; developer_dir=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ -z "$developer_dir" || -d "$developer_dir" ]] || { echo "错误：Xcode Developer 目录不存在：$developer_dir" >&2; exit 2; }
[[ -z "$developer_dir" ]] || export DEVELOPER_DIR="$developer_dir"
source_check() {
  local missing=0 command
  for command in python3 swiftc git; do
    if ! command -v "$command" >/dev/null 2>&1; then echo "错误：source 模式缺少命令：$command" >&2; missing=1; fi
  done
  (( missing == 0 )) || return 1
  echo "PASS：source 模式依赖满足。"
}
mac_setup() { bash "$root/tools/check_prototype_environment.sh" --mac; bash "$root/tools/build_video_preparer.sh"; bash "$root/tools/build_mac_training.sh"; }
viewer_setup() { bash "$root/tools/setup_mac_viewer.sh"; }
case "$mode" in
  source) source_check ;; mac) mac_setup ;; viewer) viewer_setup ;; all) source_check; mac_setup; viewer_setup ;;
esac
