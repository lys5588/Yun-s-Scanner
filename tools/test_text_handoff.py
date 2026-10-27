#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""手工文本迁移恢复器的独立单元测试。"""

import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile


MODULE_PATH = Path(__file__).with_name("restore_text_handoff.py")
SPEC = importlib.util.spec_from_file_location("restore_text_handoff", MODULE_PATH)
RESTORER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(RESTORER)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def make_bundle(root, files, *, unsafe_name=None, wrong_digest=False):
    """Build a small independent v1 fixture and return its manifest path."""
    buffer = io.BytesIO()
    names = list(files)
    if unsafe_name is not None:
        names[0] = unsafe_name
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for original, name in zip(files, names):
            info = zipfile.ZipInfo(name)
            info.external_attr = (0o100755 if original.endswith(".sh") else 0o100644) << 16
            archive.writestr(info, files[original])
    payload = buffer.getvalue()
    chunks = [payload[:len(payload) // 2], payload[len(payload) // 2:]]
    parts = []
    for index, chunk in enumerate(chunks, 1):
        name = f"source-{index:02}.txt"
        encoded = base64.b64encode(chunk).decode("ascii")
        # Simulate clipboard line ending conversion and harmless inserted spaces.
        text = " \r\n".join(encoded[offset:offset + 31] for offset in range(0, len(encoded), 31))
        (root / name).write_bytes((text + "\r\n").encode("ascii"))
        parts.append({"path": name, "bytes": len(chunk), "sha256": sha(chunk)})
    records = []
    for original, name in zip(files, names):
        data = files[original]
        digest = sha(data)
        if wrong_digest and original == next(iter(files)):
            digest = "0" * 64
        records.append({"path": name, "bytes": len(data), "sha256": digest,
                        "executable": original.endswith(".sh")})
    transfer = {"schemaVersion": 1, "projectCommit": "fixture", "profile": "manual-text",
                "upstream": {}, "contents": "测试", "excluded": [], "files": records}
    manifest = {"schemaVersion": 1, "encoding": "zip+base64-chunks-v1", "projectCommit": "fixture",
                "archive": {"bytes": len(payload), "sha256": sha(payload)}, "parts": parts,
                "transferManifest": transfer}
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")


class RestoreTextHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.files = {"src/hello world.txt": b"nihao\n", "bin/run.sh": b"#!/bin/sh\necho ok\n",
                      "Assets/icon.bin": b"\x00\xffbinary\x10"}

    def tearDown(self):
        self.temp.cleanup()

    def test_restore_binary_executable_and_clipboard_whitespace(self):
        make_bundle(self.bundle, self.files)
        output = self.root / "project"
        revision, count = RESTORER.restore(self.bundle, output)
        self.assertEqual((revision, count), ("fixture", 3))
        for name, data in self.files.items():
            self.assertEqual((output / name).read_bytes(), data)
        self.assertTrue((output / "bin/run.sh").stat().st_mode & stat.S_IXUSR)
        saved = json.loads((output / "TRANSFER_MANIFEST.json").read_text())
        self.assertEqual(saved["profile"], "manual-text")

    def test_corrupt_or_missing_part_is_rejected(self):
        make_bundle(self.bundle, self.files)
        path = self.bundle / "source-01.txt"
        path.write_text("AAAA\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "source-01.txt"):
            RESTORER.restore(self.bundle, self.root / "bad")
        make_bundle(self.bundle, self.files)
        (self.bundle / "source-02.txt").unlink()
        with self.assertRaisesRegex(ValueError, "source-02.txt"):
            RESTORER.restore(self.bundle, self.root / "missing")

    def test_single_source_file_restores_and_truncation_is_rejected(self):
        """新版单一 source.txt 必须和旧分段包一样无损且可校验。"""
        make_bundle(self.bundle, self.files)
        manifest_path = self.bundle / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        payload = b"".join(
            RESTORER._clean_base64((self.bundle / part["path"]).read_bytes(), part["path"])
            for part in manifest["parts"]
        )
        for part in manifest["parts"]:
            (self.bundle / part["path"]).unlink()
        (self.bundle / "source.txt").write_text(
            base64.b64encode(payload).decode("ascii") + "\n", encoding="ascii")
        manifest["parts"] = [{"path": "source.txt", "bytes": len(payload),
                              "sha256": sha(payload)}]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        output = self.root / "single-project"
        self.assertEqual(RESTORER.restore(self.bundle, output), ("fixture", 3))
        for name, data in self.files.items():
            self.assertEqual((output / name).read_bytes(), data)

        source_path = self.bundle / "source.txt"
        source_path.write_bytes(source_path.read_bytes()[:-5])
        with self.assertRaisesRegex(ValueError, "source.txt"):
            RESTORER.restore(self.bundle, self.root / "truncated")

    def test_unsafe_path_and_file_digest_are_rejected(self):
        make_bundle(self.bundle, self.files, unsafe_name="../outside.txt")
        with self.assertRaisesRegex(ValueError, "不安全"):
            RESTORER.restore(self.bundle, self.root / "unsafe")
        for item in self.bundle.iterdir():
            item.unlink()
        make_bundle(self.bundle, self.files, wrong_digest=True)
        with self.assertRaisesRegex(ValueError, "摘要不一致"):
            RESTORER.restore(self.bundle, self.root / "digest")

    def test_existing_output_is_untouched(self):
        make_bundle(self.bundle, self.files)
        output = self.root / "existing"
        output.mkdir()
        sentinel = output / "keep.txt"
        sentinel.write_text("do not change", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "已存在"):
            RESTORER.restore(self.bundle, output)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "do not change")

    def test_path_aliases_collisions_reserved_name_and_version_are_rejected(self):
        make_bundle(self.bundle, self.files, unsafe_name="src/../alias.txt")
        with self.assertRaisesRegex(ValueError, "不安全|不规范"):
            RESTORER.restore(self.bundle, self.root / "alias")
        for item in self.bundle.iterdir():
            item.unlink()
        make_bundle(self.bundle, {"A.txt": b"upper", "a.txt": b"lower"})
        with self.assertRaisesRegex(ValueError, "大小写"):
            RESTORER.restore(self.bundle, self.root / "collision")
        for item in self.bundle.iterdir():
            item.unlink()
        make_bundle(self.bundle, {"TRANSFER_MANIFEST.json": b"reserved"})
        with self.assertRaisesRegex(ValueError, "保留文件"):
            RESTORER.restore(self.bundle, self.root / "reserved")
        for item in self.bundle.iterdir():
            item.unlink()
        make_bundle(self.bundle, self.files)
        manifest_path = self.bundle / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["transferManifest"]["projectCommit"] = "other"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "projectCommit"):
            RESTORER.restore(self.bundle, self.root / "version")


if __name__ == "__main__":
    unittest.main()
