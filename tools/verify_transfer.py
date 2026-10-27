#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""在解压后的源码目录验证迁移包内每个文件的 SHA-256。"""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent


def verify(root):
    manifest_path = root / "TRANSFER_MANIFEST.json"
    if not manifest_path.is_file():
        raise ValueError("未找到 TRANSFER_MANIFEST.json；此检查用于源码迁移包")
    manifest = json.loads(manifest_path.read_text())
    files = manifest.get("files", [])
    if manifest.get("schemaVersion") != 1 or not files:
        raise ValueError("不支持或为空的迁移清单")
    seen = set()
    for record in files:
        name = record["path"]
        path = root / name
        if (name in seen or path.is_symlink() or not path.resolve().is_relative_to(root.resolve())
                or not path.is_file()):
            raise ValueError(f"缺失、重复或不安全的项目文件：{name}")
        seen.add(name)
        data = path.read_bytes()
        if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError(f"文件与迁移清单不一致：{name}")
    return manifest["projectCommit"], len(files)


if __name__ == "__main__":
    try:
        revision, count = verify(ROOT)
        print(f"通过：{count} 个源码文件与版本 {revision} 一致")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"迁移校验失败：{error}", file=sys.stderr)
        sys.exit(1)
