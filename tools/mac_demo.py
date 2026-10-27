#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""仅在本机运行的视频导入、Apple 摄影测量、Swift/Metal 训练与 Viewer 控制台。"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import mimetypes
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import threading
import time
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/mac-demo"
WEB = ROOT / "tools/mac_demo_web"
VIDEO_EXTENSIONS = {".mov", ".mp4", ".m4v"}
MAX_UPLOAD = 2 * 1024**3


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def inside(root, relative):
    result = (root / relative).resolve()
    if not result.is_relative_to(root.resolve()):
        raise ValueError("路径必须位于本地实验目录中")
    return result


def viewer_directory():
    checkout = BIN / "supersplat-viewer"
    for candidate in [checkout / "public", checkout / "dist", checkout / "build"]:
        if (candidate / "index.html").is_file():
            return candidate
    return checkout / "public"


def current_fingerprint(kind):
    try:
        result = subprocess.run(
            ["bash", str(ROOT / "tools/mac_toolchain_fingerprint.sh"), kind],
            capture_output=True, text=True, check=False, timeout=15)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def matches_fingerprint(filename, current):
    try:
        return current is not None and (BIN / filename).read_text().strip() == current
    except OSError:
        return False


def environment():
    training = current_fingerprint("training")
    preparer = current_fingerprint("preparer")
    return {
        "ffmpeg": bool(shutil.which("ffmpeg") and shutil.which("ffprobe")),
        "photogrammetry": ((BIN / "prepare_video_scan").is_file()
                          and matches_fingerprint("prepare_video_scan.fingerprint", preparer)),
        "trainer": ((BIN / "train_gaussians").is_file() and (BIN / "gs.metallib").is_file()
                    and matches_fingerprint("training.fingerprint", training)),
        "metal": training is not None,
        "viewer": (viewer_directory() / "index.html").is_file(),
    }


class Cancelled(Exception):
    pass


class Jobs:
    def __init__(self, data_root):
        self.root = data_root.resolve()
        self.inbox = self.root / "inbox"
        self.runs = self.root / "runs"
        self.inbox.mkdir(parents=True, exist_ok=True)
        self.runs.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.active = None
        self.process = None
        self.cancelled = threading.Event()
        for path in self.runs.glob("*/run.json"):
            try:
                state = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if state.get("status") in {"running", "queued"}:
                state.update(status="interrupted", stage="上次进程已中断",
                             error="未标记为完成；可重新创建任务，或在数据准备完成后继续训练。")
                write_json(path, state)

    def directory(self, run_id):
        if not re.fullmatch(r"\d{8}-\d{6}-[a-f0-9]{8}", run_id):
            raise ValueError("无效实验编号")
        path = self.runs / run_id
        if not path.is_dir():
            raise FileNotFoundError("实验不存在")
        return path

    def read(self, run_id, with_log=False):
        folder = self.directory(run_id)
        state = json.loads((folder / "run.json").read_text())
        state["modelReady"] = state["status"] == "completed"
        state["canResume"] = state["status"] in {
            "ready_for_training", "failed", "cancelled", "interrupted"
        } and all((folder / "scan" / name).is_file() for name in [
            "poses.jsonl", "points.ply", "video-import.json"
        ])
        if state["modelReady"]:
            state["modelURL"] = f"/data/runs/{run_id}/scan/gaussian-training/model/gaussians.ply"
            state["viewerURL"] = ("/viewer/?content=" + quote(state["modelURL"], safe="")
                                  + "&settings=%2Fviewer-settings.json&webgl")
            state["exportURL"] = f"/api/runs/{run_id}/export"
        if with_log:
            log = folder / "run.log"
            if log.exists():
                with log.open("rb") as handle:
                    handle.seek(max(0, log.stat().st_size - 32_000))
                    state["log"] = handle.read().decode("utf-8", errors="replace")
            else:
                state["log"] = ""
        return state

    def update(self, run_id, **changes):
        with self.lock:
            path = self.directory(run_id) / "run.json"
            state = json.loads(path.read_text())
            state.update(changes, updatedAt=time.time())
            write_json(path, state)

    def status(self):
        inbox = [{"name": path.name, "size": path.stat().st_size}
                 for path in sorted(self.inbox.iterdir())
                 if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
                 and path.resolve().is_relative_to(self.inbox)]
        runs = []
        for path in sorted(self.runs.glob("*/run.json"), reverse=True):
            try:
                runs.append(self.read(path.parent.name))
            except (OSError, ValueError, KeyError):
                # Preserve damaged records on disk without hiding the other experiments.
                continue
        return {"inboxPath": str(self.inbox), "environment": environment(),
                "inbox": inbox, "runs": runs, "activeRunId": self.active}

    def create(self, filename, iterations):
        with self.lock:
            if self.active:
                raise ValueError("已有任务运行，请等待或取消后重试")
            if not isinstance(filename, str):
                raise ValueError("视频文件名必须为字符串")
            source = inside(self.inbox, filename)
            if source.parent != self.inbox or not source.is_file() or source.suffix.lower() not in VIDEO_EXTENSIONS:
                raise ValueError("请先把 MOV／MP4 视频放入收件目录")
            if not isinstance(iterations, int) or isinstance(iterations, bool) or not 10 <= iterations <= 20_000:
                raise ValueError("迭代数应为 10–20000，建议首轮使用 4000")
            run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
            folder = self.runs / run_id
            folder.mkdir()
            (folder / "scan/images").mkdir(parents=True)
            write_json(folder / "run.json", {
                "id": run_id, "source": source.name, "iterations": iterations,
                "status": "queued", "stage": "等待准备", "createdAt": time.time(),
                "error": None, "modelReady": False,
            })
            self.start(run_id, resume=False)
            return run_id

    def start(self, run_id, resume):
        with self.lock:
            if self.active:
                raise ValueError("已有任务运行")
            scan = self.directory(run_id) / "scan"
            if resume and not all((scan / name).is_file() for name in ["poses.jsonl", "points.ply", "video-import.json"]):
                raise ValueError("数据尚未准备完成，请重新创建任务")
            if resume and self.read(run_id)["status"] == "completed":
                raise ValueError("已有完整结果；需要比较参数时请创建新任务")
            self.active = run_id
            self.cancelled.clear()
            self.update(run_id, status="queued", stage="等待运行", error=None)
            threading.Thread(target=self.execute, args=(run_id, resume), daemon=True).start()

    def log(self, run_id, line):
        with (self.directory(run_id) / "run.log").open("a", encoding="utf-8") as handle:
            handle.write(line.rstrip() + "\n")

    def command(self, run_id, argv, on_line=None):
        if self.cancelled.is_set():
            raise Cancelled()
        self.log(run_id, "$ " + json.dumps([str(item) for item in argv], ensure_ascii=False))
        with self.lock:
            process = subprocess.Popen(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, errors="replace", start_new_session=True)
            self.process = process
            if self.cancelled.is_set():
                os.killpg(process.pid, signal.SIGTERM)
        try:
            for line in process.stdout:
                self.log(run_id, line)
                if on_line:
                    on_line(line)
            code = process.wait()
            if self.cancelled.is_set():
                raise Cancelled()
            if code:
                raise RuntimeError(f"{Path(str(argv[0])).name} 退出码 {code}，请查看运行日志")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            process.stdout.close()
            with self.lock:
                self.process = None

    def cancel(self, run_id):
        with self.lock:
            if self.active != run_id:
                raise ValueError("该实验当前没有运行")
            self.cancelled.set()
            if self.process and self.process.poll() is None:
                process = self.process
                os.killpg(process.pid, signal.SIGTERM)
                threading.Thread(target=self.stop_after_grace, args=(process,), daemon=True).start()

    @staticmethod
    def stop_after_grace(process):
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def extract(self, run_id):
        folder = self.directory(run_id)
        state = self.read(run_id)
        source = inside(self.inbox, state["source"])
        scan = folder / "scan"
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(source)],
            capture_output=True, text=True, check=True)
        info = json.loads(probe.stdout)
        video = next((stream for stream in info["streams"] if stream["codec_type"] == "video"), None)
        if video is None:
            raise ValueError("文件没有视频轨道")
        duration = float(video.get("duration") or info.get("format", {}).get("duration") or 0)
        if duration > 180:
            raise ValueError("首版请使用不超过 3 分钟的视频，建议拍摄 30–60 秒")
        if video.get("color_transfer") in {"smpte2084", "arib-std-b67"}:
            raise ValueError("首版输入需要 SDR 视频；请关闭手机 HDR 后拍摄，或先导出 SDR 副本")
        digest = hashlib.sha256()
        with source.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                if self.cancelled.is_set():
                    raise Cancelled()
                digest.update(block)
        write_json(scan / "video-source.json", {
            "name": source.name, "sha256": digest.hexdigest(), "probe": info,
            "sourceType": "ordinary_video", "hasARKitPoses": False, "hasLiDARDepth": False,
            "timestampConvention": "decoded_source_video_seconds",
            "timestampPolicy": "preserve source PTS, including a nonzero or negative start; no rebasing",
            "extraction": "select original frames at intervals >= 0.5 s; no duplicated/interpolated images",
        })
        timestamps = []

        def record_time(line):
            match = re.search(r"\bn:\s*(\d+).*?\bpts_time:([0-9.eE+-]+)", line)
            if match:
                timestamps.append(float(match.group(2)))

        self.command(run_id, [
            "ffmpeg", "-hide_banner", "-nostdin", "-copyts", "-i", str(source), "-map", "0:v:0", "-an",
            "-vf", "select='isnan(prev_selected_t)+gte(t-prev_selected_t,0.5)',"
                   "scale=w='min(1600,iw)':h='min(1600,ih)':force_original_aspect_ratio=decrease,showinfo",
            "-fps_mode", "passthrough", "-avoid_negative_ts", "disabled", "-q:v", "2",
            str(scan / "images/frame_%06d.jpg"),
        ], record_time)
        images = sorted((scan / "images").glob("frame_*.jpg"))
        if len(images) != len(timestamps) or len(images) < 8:
            raise ValueError(f"仅提取 {len(images)} 帧／{len(timestamps)} 个时间戳；需要至少 8 个可匹配视角")
        if any(not math.isfinite(value) for value in timestamps) or any(
                b <= a for a, b in zip(timestamps, timestamps[1:])):
            raise ValueError("源视频的提取时间戳必须为有限值且严格递增")
        write_json(scan / "video-frames.json", [
            {"imageFile": image.name, "timestamp": timestamp}
            for image, timestamp in zip(images, timestamps)])
        self.update(run_id, extractedFrames=len(images))

    def execute(self, run_id, resume):
        scan = self.directory(run_id) / "scan"
        try:
            self.update(run_id, status="running", stage="抽取视频原始帧", error=None)
            if not resume:
                self.extract(run_id)
                self.update(run_id, stage="Apple 原生摄影测量：估计相机与点云")
                helper = BIN / "prepare_video_scan"
                if not environment()["photogrammetry"]:
                    self.command(run_id, ["bash", str(ROOT / "tools/build_video_preparer.sh")])
                self.command(run_id, [str(helper), str(scan / "images"), str(scan)])
            if self.cancelled.is_set():
                raise Cancelled()
            if not environment()["trainer"]:
                self.update(run_id, status="ready_for_training", stage="数据已准备，等待 Metal 训练工具",
                            error="安装完整 Xcode 和 Metal Toolchain 后，运行 bash tools/build_mac_training.sh，再点击继续训练。")
                return
            self.update(run_id, stage="Swift／Metal 高斯训练")
            self.command(run_id, [
                "bash", str(ROOT / "tools/run_mac_training.sh"), str(scan),
                "--iterations", str(self.read(run_id)["iterations"]),
            ])
            model = scan / "gaussian-training/model"
            for name in ["gaussians.sog", "gaussians.ply", "experiment.json", "gaussians.json",
                         "training-poses.jsonl", "video-import.json"]:
                if not (model / name).is_file() or (model / name).stat().st_size == 0:
                    raise RuntimeError(f"训练没有产生完整输出：{name}")
            experiment = json.loads((model / "experiment.json").read_text())
            if experiment["gaussians"] <= 0 or experiment["actualIterations"] <= 0:
                raise RuntimeError("训练输出没有有效的高斯或迭代记录")
            self.update(run_id, status="completed", stage="完成，可查看与导出",
                        gaussians=experiment["gaussians"], error=None)
        except Cancelled:
            self.update(run_id, status="cancelled", stage="已取消", error="原始视频和已生成的诊断数据已保留")
        except Exception as error:
            self.log(run_id, "失败：" + str(error))
            self.update(run_id, status="failed", stage="处理失败", error=str(error))
        finally:
            with self.lock:
                self.active = None

    def export(self, run_id):
        if self.read(run_id)["status"] != "completed":
            raise ValueError("只有完成的高斯模型可以导出")
        folder = self.directory(run_id)
        model = folder / "scan/gaussian-training/model"
        output = folder / "model.zip"
        temporary = folder / ("model-" + uuid.uuid4().hex + ".partial")
        try:
            with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(model.iterdir()):
                    if path.is_file():
                        archive.write(path, run_id + "-3dgs/" + path.name)
                if not (model / "video-import.json").is_file():
                    archive.write(folder / "scan/video-import.json", run_id + "-3dgs/video-import.json")
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
        return output


class Handler(BaseHTTPRequestHandler):
    server_version = "Local3DPrototype/1"

    def log_message(self, format, *args):
        # The browser polls status frequently; retain errors without flooding the terminal.
        if len(args) > 1 and str(args[1]) not in {"200", "304"}:
            super().log_message(format, *args)

    @property
    def jobs(self):
        return self.server.jobs

    def json(self, value, status=200):
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def file(self, path, download=False):
        if not path.is_file():
            raise FileNotFoundError("文件尚不存在")
        self.send_response(200)
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        if path.suffix in {".js", ".mjs"}:
            content_type = "text/javascript"
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(path.stat().st_size))
        if download:
            self.send_header("Content-Disposition", f"attachment; filename={quote(path.name)}")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        with path.open("rb") as handle:
            shutil.copyfileobj(handle, self.wfile, length=1024 * 1024)

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        try:
            if path == "/api/status":
                return self.json(self.jobs.status())
            match = re.fullmatch(r"/api/runs/([^/]+)(/export)?", path)
            if match:
                if match[2]:
                    return self.file(self.jobs.export(match[1]), download=True)
                return self.json(self.jobs.read(match[1], with_log=True))
            if path.startswith("/data/runs/"):
                return self.file(inside(self.jobs.runs, path.removeprefix("/data/runs/")))
            if path.startswith("/viewer/"):
                return self.file(inside(viewer_directory(), path.removeprefix("/viewer/") or "index.html"))
            return self.file(inside(WEB, path.lstrip("/") or "index.html"))
        except (OSError, ValueError) as error:
            self.json({"error": str(error)}, 404 if isinstance(error, FileNotFoundError) else 400)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        try:
            # Requests from a remote web page must not start local workloads.
            origin = self.headers.get("Origin")
            expected = f"http://127.0.0.1:{self.server.server_port}"
            alternate = f"http://localhost:{self.server.server_port}"
            if origin and origin not in {expected, alternate}:
                return self.json({"error": "只接受本机演示页面的请求"}, 403)
            length = int(self.headers.get("Content-Length", "0"))
            if path == "/api/upload":
                if not 0 < length <= MAX_UPLOAD:
                    raise ValueError("视频大小应在 0–2 GB 之间")
                name = parse_qs(parsed.query).get("name", [""])[0]
                if Path(name).name != name or "\\" in name or Path(name).suffix.lower() not in VIDEO_EXTENSIONS:
                    raise ValueError("请选择 MOV／MP4／M4V 视频")
                name = uuid.uuid4().hex[:8] + "-" + name
                target = inside(self.jobs.inbox, name)
                temporary = target.with_suffix(target.suffix + ".uploading")
                try:
                    with temporary.open("xb") as handle:
                        remaining = length
                        while remaining:
                            block = self.rfile.read(min(1024 * 1024, remaining))
                            if not block:
                                raise ValueError("上传中断")
                            handle.write(block)
                            remaining -= len(block)
                    temporary.replace(target)
                finally:
                    temporary.unlink(missing_ok=True)
                return self.json({"name": name}, 201)
            if not 0 <= length <= 8192:
                raise ValueError("请求体过大")
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise ValueError("请求体必须为 JSON 对象")
            if path == "/api/runs":
                return self.json({"id": self.jobs.create(data["file"], data.get("iterations", 4000))}, 201)
            match = re.fullmatch(r"/api/runs/([^/]+)/(resume|cancel)", path)
            if match:
                if match[2] == "resume":
                    self.jobs.start(match[1], resume=True)
                else:
                    self.jobs.cancel(match[1])
                return self.json({"id": match[1]})
            raise ValueError("未知操作")
        except (OSError, ValueError, KeyError) as error:
            self.json({"error": str(error)}, 400)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--data-root", type=Path, default=ROOT / "local-data")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.jobs = Jobs(args.data_root)
    print(f"本地演示：http://127.0.0.1:{server.server_port}", flush=True)
    print(f"视频收件目录：{server.jobs.inbox}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        if server.jobs.active:
            server.jobs.cancel(server.jobs.active)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
