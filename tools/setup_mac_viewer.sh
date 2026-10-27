#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
# Build the pinned official SuperSplat Viewer for the localhost Mac demo.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
build_root="$repo_root/.build/mac-demo"
viewer_root="$build_root/supersplat-viewer"
viewer_commit="5976646dc972e7700fbde3948465795cca0a4ebc"
viewer_url="https://github.com/playcanvas/supersplat-viewer.git"

command -v git >/dev/null || { echo "需要 git" >&2; exit 1; }
command -v npm >/dev/null || { echo "需要 Node.js 20+ 与 npm" >&2; exit 1; }
node_major=$(node -p 'process.versions.node.split(".")[0]')
(( node_major >= 20 )) || { echo "需要 Node.js 20 或更新版本" >&2; exit 1; }

mkdir -p "$build_root"
if [[ ! -d "$viewer_root/.git" ]]; then
  git clone --no-checkout "$viewer_url" "$viewer_root"
fi
git -C "$viewer_root" fetch --depth 1 origin "$viewer_commit"
git -C "$viewer_root" checkout --detach "$viewer_commit"

cd "$viewer_root"
npm ci
npm run build
[[ -f LICENSE ]] || { echo "缺少上游 MIT LICENSE" >&2; exit 1; }
[[ -f public/index.html && -f public/index.js ]] || { echo "SuperSplat Viewer 构建未生成 public 输出" >&2; exit 1; }
printf 'SuperSplat Viewer 已构建：%s\n' "$viewer_root/public"
printf '服务器应将 /viewer/ 映射到：%s\n' "$viewer_root/public"
