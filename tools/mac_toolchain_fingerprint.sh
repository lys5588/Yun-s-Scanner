#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
# Selects an installed Xcode without mutating xcode-select, then emits comparison-only build fingerprints.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
kind=${1:-}
case "$kind" in
  developer-dir|preparer-dir|preparer|training) ;;
  *) echo "用法：bash tools/mac_toolchain_fingerprint.sh developer-dir|preparer-dir|preparer|training" >&2; exit 2 ;;
esac

candidates=()
[[ -n "${DEVELOPER_DIR:-}" ]] && candidates+=("$DEVELOPER_DIR")
selected=$(xcode-select -p 2>/dev/null || true)
[[ -n "$selected" ]] && candidates+=("$selected")
[[ -d /Applications/Xcode.app/Contents/Developer ]] && candidates+=(/Applications/Xcode.app/Contents/Developer)
for app in /Applications/Xcode*.app; do
  [[ -d "$app/Contents/Developer" ]] && candidates+=("$app/Contents/Developer")
done

developer_dir=""
for candidate in "${candidates[@]}"; do
  [[ -d "$candidate" ]] || continue
  if [[ "$kind" == preparer || "$kind" == preparer-dir ]]; then
    swift=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --find swiftc 2>/dev/null || true)
    sdk=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    [[ -n "$swift" && -x "$swift" && -n "$sdk" ]] || continue
  else
    DEVELOPER_DIR="$candidate" xcodebuild -version >/dev/null 2>&1 || continue
    if [[ "$kind" == training ]]; then
      metal=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --find metal 2>/dev/null || true)
      metallib=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --find metallib 2>/dev/null || true)
      [[ -n "$metal" && -x "$metal" && -n "$metallib" && -x "$metallib" ]] || continue
    fi
  fi
  developer_dir="$candidate"
  break
done
if [[ -z "$developer_dir" ]]; then
  if [[ "$kind" == preparer || "$kind" == preparer-dir ]]; then
    echo "错误：找不到可提供 macOS Swift 编译器与 SDK 的开发者目录。" >&2
  else
    echo "错误：找不到完整 Xcode；Command Line Tools 不能生成训练构建指纹。" >&2
  fi
  exit 1
fi
if [[ "$kind" == developer-dir || "$kind" == preparer-dir ]]; then
  printf '%s\n' "$developer_dir"
  exit 0
fi

swiftc_path=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --find swiftc 2>/dev/null || true)
sdk=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
[[ -n "$swiftc_path" && -x "$swiftc_path" && -n "$sdk" ]] || { echo "错误：选定 Xcode 缺少 macOS Swift 编译器或 SDK。" >&2; exit 1; }
source_hash=$(python3 - "$root" "$kind" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
if kind == "preparer":
    files = [root / "tools" / "prepare_video_scan.swift",
             root / "tools" / "build_video_preparer.sh"]
else:
    files = [root / "tools" / "train_gaussians.swift",
             root / "tools" / "build_mac_training.sh"]
    for relative, suffixes in (("arkit-3dgs-scanner/Capture", {".swift"}),
                               ("arkit-3dgs-scanner/History", {".swift"}),
                               ("arkit-3dgs-scanner/Training", {".swift", ".metal", ".h"})):
        directory = root / relative
        files.extend(path for path in directory.rglob("*") if path.is_file() and path.suffix in suffixes)
hash_value = hashlib.sha256()
for path in sorted(files, key=lambda value: value.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix().encode()
    hash_value.update(relative + b"\0" + path.read_bytes() + b"\0")
print(hash_value.hexdigest())
PY
)
swift_version=$(DEVELOPER_DIR="$developer_dir" "$swiftc_path" --version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
printf 'format=1\nkind=%s\nhost_arch=%s\nmacos_sdk=%s\nswift=%s\nsource_sha256=%s\n' "$kind" "$(uname -m)" "$sdk" "$swift_version" "$source_hash"
if [[ "$kind" == training ]]; then
  xcode=$(DEVELOPER_DIR="$developer_dir" xcodebuild -version 2>/dev/null | tr '\n' ' ' || true)
  metal=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --find metal 2>/dev/null || true)
  metallib=$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --find metallib 2>/dev/null || true)
  [[ -n "$xcode" && -x "$metal" && -x "$metallib" ]] || { echo "错误：训练 fingerprint 需要完整 Xcode、metal 和 metallib。" >&2; exit 1; }
  printf 'xcode=%s\nmetal=%s\nmetallib=%s\n' "$(printf '%s' "$xcode" | sed 's/[[:space:]]\+/ /g')" "$(DEVELOPER_DIR="$developer_dir" "$metal" --version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')" "$(DEVELOPER_DIR="$developer_dir" "$metallib" --version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
fi
