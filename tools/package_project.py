#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""把已提交的全部项目源码打包为可迁移 ZIP，并附逐文件 SHA-256 清单。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "arkit-prototype"
MINIMAL_DIRECTORIES = {
    "arkit-3dgs-scanner",
    "arkit-3dgs-scanner.xcodeproj",
    "Config",
    "tools",
    "licenses",
}
MINIMAL_FILES = {
    ".gitignore",
    "README.md",
    "AGENTS.md",
    "LICENSE",
    "NOTICE",
    "PROTOTYPE_BASELINE.json",
}


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments], text=True).strip()


def is_minimal_file(name):
    return name in MINIMAL_FILES or name.split("/", 1)[0] in MINIMAL_DIRECTORIES


def validate_minimal_inputs(names):
    """Ensure the minimal archive remains independently usable after refactors."""
    available = set(names)
    missing = sorted(MINIMAL_FILES - available)
    for directory in sorted(MINIMAL_DIRECTORIES):
        if not any(name.startswith(f"{directory}/") for name in available):
            missing.append(f"{directory}/")
    if missing:
        raise ValueError("最小迁移包缺少必需入口：" + "、".join(missing))


def package(output=None, minimal=False):
    if not (ROOT / ".git").exists():
        raise ValueError("打包需要原始 Git 工作区；解压后的源码可以直接构建或整体复制")
    if git("status", "--porcelain"):
        raise ValueError("存在未提交变更，请先提交，以保证迁移包与版本号对应")
    revision = git("rev-parse", "HEAD")
    profile = "minimal" if minimal else "full"
    default_name = (f"arkit-prototype-minimal-{revision[:12]}.zip" if minimal
                    else f"arkit-prototype-{revision[:12]}.zip")
    output = Path(output or ROOT / ".build" / "handoff" / default_name).resolve()
    if output.exists():
        raise ValueError(f"输出已存在，请使用新的 --output 路径：{output}")
    names = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-z"], text=True).split("\0")
    names = sorted(filter(None, names))
    if minimal:
        validate_minimal_inputs(names)
        names = [name for name in names if is_minimal_file(name)]
    files = []
    for name in names:
        path = ROOT / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT):
            raise ValueError(f"无法打包非普通项目文件：{name}")
        files.append((name, path))
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest = {
        "schemaVersion": 1,
        "projectCommit": revision,
        "profile": profile,
        "upstream": json.loads((ROOT / "PROTOTYPE_BASELINE.json").read_text()),
        "contents": ("最小可构建程序、Xcode 工程、许可证、迁移说明和验证脚本"
                     if minimal else "全部已提交源码、Xcode 工程、资源、模块文档、许可证和验证脚本"),
        "excluded": (["docs/", ".git/", ".build/", "local-data/", "私有扫描、签名身份与本机缓存"]
                     if minimal else [".git/", ".build/", "local-data/", "私有扫描、签名身份与本机缓存"]),
        "dependencies": "另一台 Mac 安装 Xcode/Metal、FFmpeg、Node.js 后运行 setup_project.sh；Viewer 依赖按固定版本联网下载",
        "files": [],
    }
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".transfer-", suffix=".zip", delete=False) as handle:
        temporary = Path(handle.name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            archive.comment = f"projectCommit={revision}".encode()
            for name, path in files:
                data = path.read_bytes()
                info = zipfile.ZipInfo.from_file(path, arcname=f"{PREFIX}/{name}")
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data)
                manifest["files"].append({
                    "path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()
                })
            archive.writestr(f"{PREFIX}/TRANSFER_MANIFEST.json",
                             json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip():
                raise ValueError("归档 CRC 校验失败")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output, len(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="输出 ZIP 路径；默认位于 .build/handoff/")
    parser.add_argument("--minimal", action="store_true",
                        help="只包含程序、README、AGENTS、许可证与工具；不包含 docs/")
    args = parser.parse_args()
    try:
        output, count = package(args.output, minimal=args.minimal)
        print(f"迁移包：{output}\n源码文件：{count}\n大小：{output.stat().st_size / 1024**2:.1f} MiB")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"打包失败：{error}\n")


if __name__ == "__main__":
    main()
