#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""将手工复制的 base64 文本包无损恢复成项目目录。"""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import shlex
import sys
import tempfile
from typing import Dict, Iterable, Tuple
import unicodedata
import zipfile


MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _safe_relative_path(value: object) -> str:
    """Return a portable relative file name, rejecting archive extraction tricks."""
    _require(isinstance(value, str) and value, "迁移清单包含空或非文本路径")
    _require(not any(ord(character) < 32 or ord(character) == 127 for character in value),
             f"不安全的项目路径：{value}")
    _require("\\" not in value and not value.startswith("/"), f"不安全的项目路径：{value}")
    path = PurePosixPath(value)
    _require(not path.is_absolute() and path.parts, f"不安全的项目路径：{value}")
    _require(all(part not in ("", ".", "..") for part in path.parts), f"不安全的项目路径：{value}")
    _require(not re.match(r"^[A-Za-z]:", path.parts[0]), f"不安全的项目路径：{value}")
    _require(value == path.as_posix(), f"不规范的项目路径：{value}")
    return value


def _read_manifest(bundle_dir: Path) -> dict:
    manifest_path = bundle_dir / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValueError("未找到 manifest.json") from error
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"无法读取 manifest.json：{error}") from error
    _require(isinstance(manifest, dict), "manifest.json 必须是对象")
    _require(manifest.get("schemaVersion") == 1,
             "不支持的手工文本包清单版本")
    _require(manifest.get("encoding") == "zip+base64-chunks-v1",
             "不支持的手工文本包编码")
    return manifest


def _clean_base64(raw: bytes, part_name: str) -> bytes:
    allowed_whitespace = b" \t\r\n"
    clean = bytearray()
    for value in raw:
        if 65 <= value <= 90 or 97 <= value <= 122 or 48 <= value <= 57 or value in (43, 47, 61):
            clean.append(value)
        elif value not in allowed_whitespace:
            raise ValueError(f"片段 {part_name} 含有非 Base64 字符，请重新复制该文件")
    try:
        return base64.b64decode(bytes(clean), validate=True)
    except (ValueError, UnicodeError) as error:
        raise ValueError(f"片段 {part_name} 不是有效 Base64，请重新复制该文件") from error


def _read_archive(bundle_dir: Path, manifest: dict) -> bytes:
    archive = manifest.get("archive")
    parts = manifest.get("parts")
    _require(isinstance(archive, dict) and isinstance(parts, list) and parts,
             "手工文本包缺少 archive 或 parts")
    archive_bytes = archive.get("bytes")
    archive_hash = archive.get("sha256")
    _require(isinstance(archive_bytes, int) and 0 < archive_bytes <= MAX_ARCHIVE_BYTES,
             "archive 大小无效或超过安全上限")
    _require(isinstance(archive_hash, str) and HEX_SHA256.fullmatch(archive_hash),
             "archive SHA-256 无效")

    chunks = []
    names = set()
    for record in parts:
        _require(isinstance(record, dict), "parts 包含无效记录")
        name = record.get("path")
        expected_bytes = record.get("bytes")
        expected_hash = record.get("sha256")
        _require(isinstance(name, str) and
                 (name == "source.txt" or re.fullmatch(r"source-\d{2,}\.txt", name)),
                 "parts 包含无效文件名")
        if name == "source.txt":
            _require(len(parts) == 1,
                     "source.txt 单文件包不能与分段 source-*.txt 混用")
        _require(name not in names, f"parts 中重复的文件名：{name}")
        names.add(name)
        _require(isinstance(expected_bytes, int) and expected_bytes >= 0,
                 f"片段 {name} 大小无效")
        _require(isinstance(expected_hash, str) and HEX_SHA256.fullmatch(expected_hash),
                 f"片段 {name} SHA-256 无效")
        part_path = bundle_dir / name
        try:
            chunk = _clean_base64(part_path.read_bytes(), name)
        except FileNotFoundError as error:
            raise ValueError(f"缺少片段 {name}，请补复制该文件") from error
        except OSError as error:
            raise ValueError(f"无法读取片段 {name}：{error}") from error
        _require(len(chunk) == expected_bytes and _sha256(chunk) == expected_hash,
                 f"片段 {name} 摘要不匹配，请重新复制该文件")
        chunks.append(chunk)
    payload = b"".join(chunks)
    _require(len(payload) == archive_bytes and _sha256(payload) == archive_hash,
             "全部片段拼接后的 archive 摘要不匹配，请检查 manifest.json 与所有 source 文件")
    return payload


def _file_records(manifest: dict) -> Dict[str, dict]:
    transfer = manifest.get("transferManifest")
    _require(isinstance(transfer, dict) and transfer.get("schemaVersion") == 1,
             "缺少或不支持 transferManifest")
    _require(transfer.get("projectCommit") == manifest.get("projectCommit"),
             "transferManifest 与主清单的 projectCommit 不一致")
    records = transfer.get("files")
    _require(isinstance(records, list) and records, "transferManifest.files 为空")
    result: Dict[str, dict] = {}
    normalized: Dict[str, str] = {}
    for record in records:
        _require(isinstance(record, dict), "迁移文件记录无效")
        name = _safe_relative_path(record.get("path"))
        _require(name not in result, f"迁移清单存在重复路径：{name}")
        normalized_name = unicodedata.normalize("NFC", name).casefold()
        _require(normalized_name not in normalized,
                 f"迁移清单存在大小写或 Unicode 冲突路径：{name} 与 {normalized.get(normalized_name)}")
        _require(normalized_name != "transfer_manifest.json",
                 "迁移清单不能包含保留文件 TRANSFER_MANIFEST.json")
        _require(normalized_name != ".git" and not normalized_name.startswith(".git/"),
                 "迁移清单不能包含 .git/ 路径")
        size = record.get("bytes")
        digest = record.get("sha256")
        executable = record.get("executable")
        _require(isinstance(size, int) and 0 <= size <= MAX_UNCOMPRESSED_BYTES,
                 f"迁移文件大小无效：{name}")
        _require(isinstance(digest, str) and HEX_SHA256.fullmatch(digest),
                 f"迁移文件 SHA-256 无效：{name}")
        _require(isinstance(executable, bool), f"迁移文件 executable 无效：{name}")
        result[name] = record
        normalized[normalized_name] = name
    for normalized_name, name in normalized.items():
        pieces = normalized_name.split("/")
        for index in range(1, len(pieces)):
            ancestor = "/".join(pieces[:index])
            if ancestor in normalized:
                raise ValueError(f"迁移清单存在文件与目录冲突：{normalized[ancestor]} 与 {name}")
    _require(sum(record["bytes"] for record in result.values()) <= MAX_UNCOMPRESSED_BYTES,
             "迁移文件总大小超过安全上限")
    return result


def _zip_entries(payload: bytes, expected: Dict[str, dict]) -> Iterable[zipfile.ZipInfo]:
    try:
        archive = zipfile.ZipFile(io.BytesIO(payload))
    except (OSError, zipfile.BadZipFile) as error:
        raise ValueError(f"archive 不是有效 ZIP：{error}") from error
    with archive:
        infos = archive.infolist()
        names = []
        for info in infos:
            name = _safe_relative_path(info.filename)
            _require(not info.is_dir(), f"ZIP 内不允许目录条目：{name}")
            _require(not (info.flag_bits & 0x1), f"ZIP 内不允许加密条目：{name}")
            mode_type = (info.external_attr >> 16) & 0o170000
            _require(mode_type != 0o120000, f"ZIP 内不允许符号链接：{name}")
            names.append(name)
        _require(len(names) == len(set(names)), "ZIP 内存在重复路径")
        _require(set(names) == set(expected), "ZIP 文件列表与迁移清单不一致")
        for info, name in zip(infos, names):
            record = expected[name]
            _require(info.file_size == record["bytes"], f"ZIP 文件大小不一致：{name}")
            try:
                data = archive.read(info)
            except (OSError, zipfile.BadZipFile) as error:
                raise ValueError(f"无法读取 ZIP 文件：{name}: {error}") from error
            _require(len(data) == record["bytes"] and _sha256(data) == record["sha256"],
                     f"ZIP 文件摘要不一致：{name}")
            yield info


def restore(bundle_dir: Path, output: Path) -> Tuple[str, int]:
    """Validate a text handoff and atomically create *output*.

    The output must not exist.  No project file is written until every source
    part, ZIP entry and declared file digest has been validated.
    """
    bundle_dir = Path(bundle_dir).resolve()
    output = Path(output)
    _require(bundle_dir.is_dir(), f"输入目录不存在：{bundle_dir}")
    _require(not output.exists() and not output.is_symlink(), f"输出目录已存在：{output}")
    parent = output.parent.resolve()
    _require(parent.is_dir(), f"输出目录的父目录不存在：{parent}")
    manifest = _read_manifest(bundle_dir)
    payload = _read_archive(bundle_dir, manifest)
    expected = _file_records(manifest)

    # Fully validate before creating a destination directory.
    infos = list(_zip_entries(payload, expected))
    revision = manifest.get("projectCommit")
    _require(isinstance(revision, str) and revision, "projectCommit 无效")
    stage = Path(tempfile.mkdtemp(prefix=".restore-text-handoff-", dir=parent))
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            for info in infos:
                name = _safe_relative_path(info.filename)
                record = expected[name]
                target = stage.joinpath(*PurePosixPath(name).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                data = archive.read(info)
                with target.open("wb") as handle:
                    handle.write(data)
                target.chmod(0o755 if record["executable"] else 0o644)
        manifest_target = stage / "TRANSFER_MANIFEST.json"
        manifest_target.write_text(json.dumps(manifest["transferManifest"], ensure_ascii=False,
                                               indent=2, sort_keys=True) + "\n", encoding="utf-8")
        manifest_target.chmod(0o644)
        _require(not output.exists() and not output.is_symlink(), f"输出目录已存在：{output}")
        os.replace(stage, output)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return revision, len(expected)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="恢复手工复制的 ARKit 原型文本包")
    parser.add_argument("--input", type=Path, default=Path(__file__).resolve().parent,
                        help="包含 manifest.json 和 source-*.txt 的目录")
    parser.add_argument("--output", type=Path, default=None, help="新项目目录（必须不存在）")
    args = parser.parse_args(argv)
    output = args.output if args.output is not None else args.input / "project"
    try:
        revision, count = restore(args.input, output)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(f"恢复失败：{error}", file=sys.stderr)
        return 1
    print(f"恢复完成：{count} 个项目文件，版本 {revision}")
    print(f"下一步：cd {shlex.quote(str(output))} && python3 tools/verify_transfer.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
