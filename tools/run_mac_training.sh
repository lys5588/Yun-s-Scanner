#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
# Runs the Mac research trainer on a converted real-SfM scan. The scan must contain matching
# images, FrameRecord poses, intrinsics and a real seed cloud; this script never creates poses.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli="$root/.build/mac-demo/train_gaussians"
metallib="$root/.build/mac-demo/gs.metallib"
stamp="$root/.build/mac-demo/training.fingerprint"

usage() {
  cat >&2 <<'MESSAGE'
用法：bash tools/run_mac_training.sh SCAN_DIR [--iterations N]

SCAN_DIR 必须是由真实 SfM/转换器生成的项目扫描目录，包含 images/、poses.jsonl（或复核姿态）
和真实点云。默认使用 Quick：960 px、4,000 iterations、300,000 Gaussians。
没有 LiDAR 的普通视频/SfM 导入会关闭深度 seeds、深度损失和位姿再次精修。
结果仅在完整训练与导出成功后发布到：SCAN_DIR/gaussian-training/model
MESSAGE
  exit 2
}

[[ $# -ge 1 ]] || usage
scan=$1
shift
iterations=4000
while [[ $# -gt 0 ]]; do
  case $1 in
    --iterations)
      [[ $# -ge 2 ]] || usage
      iterations=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
[[ "$iterations" =~ ^[1-9][0-9]*$ ]] || { echo "错误：--iterations 必须为正整数。" >&2; exit 2; }
[[ -x "$cli" && -f "$metallib" && -f "$stamp" ]] || {
  echo "错误：未找到 Mac 训练构建产物。请先运行：bash tools/build_mac_training.sh" >&2
  exit 1
}
if ! current_stamp=$(bash "$root/tools/mac_toolchain_fingerprint.sh" training 2>/dev/null) || [[ "$(cat "$stamp")" != "$current_stamp" ]]; then
  echo "错误：Mac 训练产物与当前主机或 Xcode/Metal 工具链不匹配。请在此 Mac 运行：bash tools/setup_project.sh mac" >&2
  exit 1
fi
[[ -d "$scan" ]] || { echo "错误：SCAN_DIR 不是目录：$scan" >&2; exit 2; }
[[ -d "$scan/images" ]] || { echo "错误：扫描目录缺少 images/：$scan" >&2; exit 2; }
[[ -f "$scan/poses.jsonl" || -f "$scan/review-poses.jsonl" || -f "$scan/poses_refined.jsonl" ]] || {
  echo "错误：扫描目录缺少 FrameRecord 位姿 JSONL；请先完成真实 SfM 转换。" >&2
  exit 2
}
[[ -f "$scan/points.ply" || -f "$scan/review.ply" ]] || {
  echo "错误：扫描目录缺少真实 SfM 点云 points.ply/review.ply；不会以伪造点云训练。" >&2
  exit 2
}

training_root="$scan/gaussian-training"
model_dir="$training_root/model"
log="$training_root/mac-training.log"
staging="$training_root/.mac-training-staging-$$"
[[ ! -e "$model_dir" ]] || {
  echo "错误：目标模型目录已存在：$model_dir。为避免覆盖已发布模型，本次未运行。" >&2
  exit 1
}
mkdir -p "$training_root"
mkdir "$staging"
cleanup() { [[ -d "$staging" ]] && rm -rf "$staging"; }
trap cleanup EXIT

log_tmp="$training_root/.mac-training-log-$$"
set +e
"$cli" "$metallib" "$scan" \
  --preset quick --iterations "$iterations" --long-edge 960 --max-gaussians 300000 \
  --no-depth-seeds --depth-loss 0 --no-pose --no-ppisp --selection captured --save-model "$staging" \
  2>&1 | tee "$log_tmp"
pipe_status=("${PIPESTATUS[@]}")
set -e
mv -f "$log_tmp" "$log"
if [[ ${pipe_status[0]} -ne 0 ]]; then
  echo "训练失败，已保留日志：$log；未发布模型。" >&2
  exit "${pipe_status[0]}"
fi
if [[ ${pipe_status[1]} -ne 0 ]]; then
  echo "日志写入失败，未发布模型。" >&2
  exit "${pipe_status[1]}"
fi
[[ -f "$staging/gaussians.sog" && -f "$staging/gaussians.ply" && -f "$staging/experiment.json" ]] || {
  echo "训练导出不完整，未发布模型。日志：$log" >&2
  exit 1
}
# `model` did not exist at start, so this rename cannot merge partial content into an old model.
mv "$staging" "$model_dir"
trap - EXIT
echo "训练完成：$model_dir"
echo "日志：$log"
