#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""生成仅需手工复制 5 个文件、源码集中在 source.txt 的无损交接版本。"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import zipfile

from package_project import ROOT, git, is_minimal_file, validate_minimal_inputs
from restore_text_handoff import restore

def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def agent_instructions(revision, count):
    return f"""# 文本迁移版本：新电脑接手指令

这个目录是手工复制的运输容器，不是源码根目录。共 5 个文件：本文件、`to-do.md`、`restore.py`、`manifest.json`、`source.txt`。所有源码都合并在一个 source.txt 中。用户只需保持这些文件名，将文件全文保存到同一个目录；不需要手工建立 App 目录。使用本目录的五个文件，不要混用旧分段版的脚本和清单。

## 第一件事：完整恢复

先读 `to-do.md`。检查 5 个文件齐全后，在本目录运行：

```sh
python3 restore.py
```

只需要 Python 3.9 或更高版本和标准库，恢复过程不需要 Xcode、Git、联网或额外软件包。默认输出到新的 `project/`；也可使用 `python3 restore.py --output /目标路径/ARkit-project`，目标目录必须不存在。不要为了重试删除已有项目或覆盖用户修改。

source.txt 是完整 ZIP 的 Base64 文本，包含 {count} 个原始项目文件，包括图标。它不是可以修改的源码。**不要让 AI 猜测文件边界、重新生成源码、删掉不理解的内容，或把聊天代码围栏保存进文件。** 必须使用恢复脚本；脚本会校验 source.txt、总包和每个文件的字节数与 SHA-256，再还原原始目录、内容和可执行权限。复制时换行变成 CRLF 或增加空白不影响校验。遗漏、截断或内容改变会报错；按提示重新复制对应文件，不能跳过校验。

源版本为 `{revision}`。解包成功后：

```sh
cd project
python3 tools/verify_transfer.py
python3 tools/check_project.py
```

进入 `project/` 后，以其中原始的 `AGENTS.md` 和 `README.md` 为项目指令与完整计划，结合 `PROTOTYPE_BASELINE.json`、`LICENSE`、`NOTICE` 继续。不要把本运输容器的 `to-do.md` 再复制成项目内重复的计划文档。

## 继续开发的边界

- 当前只交接代码，没有真实视频、已验收模型或可运行的旧机器构建产物。完整 Metal 训练、真实视频重建、iOS 编译和真机验收尚未完成。
- 顺序：普通手机视频在新 Mac 处理、训练与查看 → 同一模型导入 iPhone 查看 → ARKit/LiDAR 采集、端侧训练与查看。Mac 结果不能代替手机验收。
- 目标设备和 SDK API 以新机器及真机检查为准；遇到 Xcode、签名、设备信任等需要人工的操作时再请用户介入。
- 所有程序、资源、验证工具、LICENSE、NOTICE、licenses/ 原文均在包内；不要重新 clone 上游覆盖本地修改。旧 `docs/` 未带入，按恢复后的 README 第 7 节和实际验证逐步补四份简体中文模块文档。
- 第三方依赖由项目脚本按固定版本恢复；许可证不能让 AI 重写、翻译或省略。源代码仍是非商业科研用途。
- 先验证迁移，再修改源码；保留他人的工作，不向上游推送。其余协作规则见恢复后的 AGENTS.md。
"""


def write_bundle(root, names, revision, output):
    """写入独立运输容器，并用交付给目标机器的恢复器实际还原校验。"""
    root, output = Path(root).resolve(), Path(output).resolve()
    if output.exists():
        raise ValueError(f"输出目录已存在，请换用新的 --output 路径：{output}")
    validate_minimal_inputs(names)
    selected = sorted(name for name in names if is_minimal_file(name))
    transfer = {
        "schemaVersion": 1,
        "projectCommit": revision,
        "profile": "manual-text",
        "upstream": json.loads((root / "PROTOTYPE_BASELINE.json").read_text(encoding="utf-8")),
        "contents": "全部程序、Xcode 工程、资源、验证工具、原始许可证与 README/AGENTS；源码合并为 source.txt 的 5 文件迁移版本",
        "excluded": ["docs/", ".git/", ".build/", "local-data/", "私有视频、扫描、模型、签名身份和本机缓存"],
        "dependencies": "恢复只需 Python 标准库；构建和第三方 Viewer 依赖按 README 在新 Mac 安装",
        "files": [],
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in selected:
            path = root / name
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
                raise ValueError(f"不能打包非普通项目文件：{name}")
            data = path.read_bytes()
            executable = bool(path.stat().st_mode & 0o111)
            transfer["files"].append({
                "path": name, "bytes": len(data), "sha256": digest(data), "executable": executable,
            })
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data, compresslevel=9)
    payload = buffer.getvalue()
    manifest = {
        "schemaVersion": 1,
        "encoding": "zip+base64-chunks-v1",
        "projectCommit": revision,
        "archive": {"bytes": len(payload), "sha256": digest(payload)},
        "parts": [],
        "transferManifest": transfer,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".text-handoff-", dir=output.parent) as temporary:
        bundle = Path(temporary) / "bundle"
        bundle.mkdir()
        encoded = base64.b64encode(payload).decode("ascii")
        lines = (encoded[offset:offset + 96] for offset in range(0, len(encoded), 96))
        (bundle / "source.txt").write_text("\n".join(lines) + "\n", encoding="ascii")
        manifest["parts"].append({"path": "source.txt", "bytes": len(payload), "sha256": digest(payload)})
        write_json(bundle / "manifest.json", manifest)
        (bundle / "restore.py").write_bytes((root / "tools/restore_text_handoff.py").read_bytes())
        (bundle / "AGENTS.md").write_text(agent_instructions(revision, len(selected)), encoding="utf-8")
        plan = ("# 文本迁移待办与完整项目计划\n\n"
                "先按同目录 AGENTS.md 运行 `python3 restore.py`，再进入恢复的 `project/` 继续开发。"
                "5 个文件全部放在同一目录，原样复制全文，不要手动解读或改写 source.txt，也不要混用旧版文件。\n\n"
                "- [ ] 复制 5 个文件，运行恢复脚本；文件损坏时只重拷报错项。\n"
                "- [ ] 在 project/ 中运行迁移校验与源码检查。\n"
                "- [ ] 在新 Mac 配齐完整 Xcode/Metal 工具链，完成真实视频重建与 Viewer 验证。\n"
                "- [ ] 导出同一模型到手机查看，再验收手机采集、训练、查看闭环。\n"
                "- [ ] 根据实际结果更新 README，逐步编写四份简体中文模块文档，保留许可原文。\n\n"
                "下文是生成迁移版本时 README 的完整快照，包含功能安排、当前限制、验证命令、"
                "下一步、docs 编写内容以及来源与许可证。它是交接参考；恢复后只维护 project/README.md，"
                "不需要同步这份快照，也不需要重新逐个复制下文列出的源码。\n\n---\n\n"
                + (root / "README.md").read_text(encoding="utf-8"))
        (bundle / "to-do.md").write_text(plan, encoding="utf-8")
        if len(list(bundle.iterdir())) != 5:
            raise ValueError("运输容器必须恰好包含 5 个文件")
        restored_revision, restored_count = restore(bundle, Path(temporary) / "restored")
        if (restored_revision, restored_count) != (revision, len(selected)):
            raise ValueError("恢复自检与源版本或文件数不一致")
        for record in transfer["files"]:
            restored = Path(temporary) / "restored" / record["path"]
            if restored.read_bytes() != (root / record["path"]).read_bytes():
                raise ValueError(f"恢复自检发现字节差异：{record['path']}")
        bundle.rename(output)
    return len(selected), len(payload)


def build(output=None):
    if not (ROOT / ".git").exists():
        raise ValueError("生成运输容器需要原始 Git 工作区；恢复过程不需要 Git")
    if git("status", "--porcelain"):
        raise ValueError("请先提交工作区修改，确保交接内容与记录的源码版本一致")
    revision = git("rev-parse", "HEAD")
    names = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"], text=True).split("\0")
    output = Path(output or ROOT / ".build" / "manual-transfer" / revision[:12]).resolve()
    count, size = write_bundle(ROOT, list(filter(None, names)), revision, output)
    print(f"完成：{output}\n只需复制 5 个文件，可恢复 {count} 个原始文件（源码合并在 source.txt 中）。")
    print(f"内部源码包 {size:,} 字节；已实际恢复并逐文件验证一致。")
    print("新电脑：将 5 个文件放在同一目录，运行 python3 restore.py，再进入 project/。")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="新的输出目录，不能已存在")
    options = parser.parse_args()
    try:
        build(options.output)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"文本迁移版本生成失败：{error}\n")
