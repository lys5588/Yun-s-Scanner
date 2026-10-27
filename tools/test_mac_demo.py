#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""本机视频导入、任务终态和 HTTP 接口验证；不代替真实摄影测量或高斯训练。"""
import http.client
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

import mac_demo as demo


class DemoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.jobs = demo.Jobs(Path(self.temp.name))
        self.source = self.jobs.inbox / "测试视频.mov"
        self.source.write_bytes(b"test placeholder, not a valid video")

    def tearDown(self):
        self.temp.cleanup()

    def create_run(self):
        with patch.object(self.jobs, "start"):
            return self.jobs.create(self.source.name, 4000)

    def test_paths_and_parameters(self):
        for name in ["../outside.mov", "/tmp/outside.mov", None]:
            with self.assertRaises(ValueError):
                self.jobs.create(name, 4000)
        for iterations in [True, 9, 20001, 1.5, "4000"]:
            with self.assertRaises(ValueError):
                self.jobs.create(self.source.name, iterations)
        with self.assertRaises(ValueError):
            demo.inside(self.jobs.runs, "../inbox")

    def test_restart_marks_incomplete_run(self):
        run_id = self.create_run()
        self.jobs.update(run_id, status="running")
        restarted = demo.Jobs(self.jobs.root)
        run = restarted.read(run_id)
        self.assertEqual(run["status"], "interrupted")
        self.assertFalse(run["modelReady"])
        self.assertFalse(run["canResume"])

    def test_missing_preparation_cannot_resume_or_export(self):
        run_id = self.create_run()
        with self.assertRaises(ValueError):
            self.jobs.start(run_id, resume=True)
        with self.assertRaises(ValueError):
            self.jobs.export(run_id)

    def test_waiting_for_toolchain_is_not_completed(self):
        run_id = self.create_run()
        with patch.object(self.jobs, "extract"), patch.object(self.jobs, "command"), \
                patch.object(demo, "environment", return_value={"trainer": False, "photogrammetry": True}):
            self.jobs.execute(run_id, resume=False)
        run = self.jobs.read(run_id)
        self.assertEqual(run["status"], "ready_for_training")
        self.assertFalse(run["modelReady"])
        with self.assertRaises(ValueError):
            self.jobs.export(run_id)

    def test_failed_native_process_is_not_completed(self):
        run_id = self.create_run()
        with patch.object(self.jobs, "extract"), \
                patch.object(self.jobs, "command", side_effect=RuntimeError("pose estimation failed")), \
                patch.object(demo, "environment", return_value={"photogrammetry": True}):
            self.jobs.execute(run_id, resume=False)
        run = self.jobs.read(run_id)
        self.assertEqual(run["status"], "failed")
        self.assertIn("pose estimation failed", run["error"])
        self.assertFalse(run["modelReady"])
        self.assertIsNone(self.jobs.active)

    def test_missing_model_is_not_completed(self):
        run_id = self.create_run()
        with patch.object(self.jobs, "command"), \
                patch.object(demo, "environment", return_value={"trainer": True}):
            self.jobs.execute(run_id, resume=True)
        run = self.jobs.read(run_id)
        self.assertEqual(run["status"], "failed")
        self.assertIn("gaussians.sog", run["error"])
        self.assertFalse(run["modelReady"])

    def test_cancelled_run_is_not_completed(self):
        run_id = self.create_run()
        with patch.object(self.jobs, "extract", side_effect=demo.Cancelled):
            self.jobs.execute(run_id, resume=False)
        self.assertEqual(self.jobs.read(run_id)["status"], "cancelled")

    def test_model_without_phone_viewer_poses_is_not_completed(self):
        run_id = self.create_run()
        model = self.jobs.directory(run_id) / "scan/gaussian-training/model"
        model.mkdir(parents=True)
        # Stub outputs exercise task state only; these are not reconstructed models.
        for name in ["gaussians.sog", "gaussians.ply", "experiment.json", "gaussians.json"]:
            (model / name).write_bytes(b"placeholder")
        with patch.object(self.jobs, "command"), \
                patch.object(demo, "environment", return_value={"trainer": True}):
            self.jobs.execute(run_id, resume=True)
        run = self.jobs.read(run_id)
        self.assertEqual(run["status"], "failed")
        self.assertIn("training-poses.jsonl", run["error"])
        self.assertFalse(run["modelReady"])

    def test_can_resume_requires_all_prepared_files(self):
        run_id = self.create_run()
        self.jobs.update(run_id, status="ready_for_training")
        scan = self.jobs.directory(run_id) / "scan"
        for name in ["poses.jsonl", "points.ply"]:
            (scan / name).touch()
        self.assertFalse(self.jobs.read(run_id)["canResume"])
        (scan / "video-import.json").touch()
        self.assertTrue(self.jobs.read(run_id)["canResume"])

    def test_copied_or_stale_binaries_are_not_ready(self):
        binary_root = self.jobs.root / "build"
        binary_root.mkdir()
        for name in ["prepare_video_scan", "train_gaussians", "gs.metallib"]:
            (binary_root / name).touch()
        with patch.object(demo, "BIN", binary_root), \
                patch.object(demo, "current_fingerprint", return_value="current-toolchain-and-source"):
            status = demo.environment()
            self.assertFalse(status["trainer"])
            self.assertFalse(status["photogrammetry"])
            for name in ["training.fingerprint", "prepare_video_scan.fingerprint"]:
                (binary_root / name).write_text("other-computer-or-old-source")
            self.assertFalse(demo.environment()["trainer"])
            for name in ["training.fingerprint", "prepare_video_scan.fingerprint"]:
                (binary_root / name).write_text("current-toolchain-and-source")
            self.assertTrue(demo.environment()["trainer"])
            self.assertTrue(demo.environment()["photogrammetry"])

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "需要 FFmpeg")
    def test_real_video_frame_extraction(self):
        subprocess.run([
            "ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=640x360:rate=30:duration=5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", str(self.source)
        ], check=True)
        run_id = self.create_run()
        self.jobs.extract(run_id)
        scan = self.jobs.directory(run_id) / "scan"
        records = json.loads((scan / "video-frames.json").read_text())
        self.assertEqual(len(records), 10)
        timestamps = [row["timestamp"] for row in records]
        self.assertEqual(timestamps[0], 0)
        self.assertTrue(all(b > a for a, b in zip(timestamps, timestamps[1:])))
        self.assertTrue(all((scan / "images" / row["imageFile"]).is_file() for row in records))
        provenance = json.loads((scan / "video-source.json").read_text())
        self.assertFalse(provenance["hasARKitPoses"])
        self.assertFalse(provenance["hasLiDARDepth"])
        self.assertEqual(len(provenance["sha256"]), 64)
        self.assertFalse((scan / "poses.jsonl").exists())
        self.assertFalse((scan / "points.ply").exists())

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "需要 FFmpeg")
    def test_nonzero_source_timestamps_are_preserved(self):
        subprocess.run([
            "ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=320x240:rate=30:duration=5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-output_ts_offset", "10", str(self.source)
        ], check=True)
        decoded = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
            "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", str(self.source)
        ]))
        source_times = [float(frame["best_effort_timestamp_time"]) for frame in decoded["frames"]]
        self.assertEqual(source_times[0], 10)
        run_id = self.create_run()
        self.jobs.extract(run_id)
        scan = self.jobs.directory(run_id) / "scan"
        records = json.loads((scan / "video-frames.json").read_text())
        timestamps = [row["timestamp"] for row in records]
        self.assertEqual(timestamps, [10 + index * 0.5 for index in range(10)])
        self.assertTrue(all(value in source_times for value in timestamps))
        self.assertEqual(len(records), len(list((scan / "images").glob("frame_*.jpg"))))

    def test_negative_source_timestamps_are_preserved(self):
        # Exercise signed decoder output directly: MOV muxers may use an edit list to
        # discard negative-PTS preroll, so remuxing is not a reliable negative fixture.
        run_id = self.create_run()
        scan = self.jobs.directory(run_id) / "scan"
        timestamps = [-2 + index * 0.5 for index in range(10)]
        probe = subprocess.CompletedProcess([], 0, stdout=json.dumps({
            "streams": [{"codec_type": "video", "duration": "5", "start_time": "-2"}]
        }))

        def emit_frames(_run_id, _argv, on_line):
            for index, timestamp in enumerate(timestamps):
                (scan / "images" / f"frame_{index + 1:06d}.jpg").write_bytes(b"extraction-state placeholder")
                on_line(f"[Parsed_showinfo] n: {index} pts: {index} pts_time:{timestamp}")

        with patch.object(demo.subprocess, "run", return_value=probe), \
                patch.object(self.jobs, "command", side_effect=emit_frames):
            self.jobs.extract(run_id)
        records = json.loads((scan / "video-frames.json").read_text())
        self.assertEqual([row["timestamp"] for row in records], timestamps)
        provenance = json.loads((scan / "video-source.json").read_text())
        self.assertEqual(provenance["timestampConvention"], "decoded_source_video_seconds")
        self.assertIn("no rebasing", provenance["timestampPolicy"])

    def test_http_import_and_invalid_requests(self):
        server = demo.ThreadingHTTPServer(("127.0.0.1", 0), demo.Handler)
        server.jobs = self.jobs
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=10)
        try:
            connection.request("GET", "/")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIn("本机", response.read().decode())
            connection.request("POST", "/api/upload?name=sample.mp4", body=b"video-data")
            response = connection.getresponse()
            self.assertEqual(response.status, 201)
            filename = json.loads(response.read())["name"]
            self.assertEqual((self.jobs.inbox / filename).read_bytes(), b"video-data")
            for body in [b"[]", b"null", b'{"file": null}', b'{"file":"../outside.mov"}']:
                connection.request("POST", "/api/runs", body=body)
                response = connection.getresponse()
                self.assertEqual(response.status, 400)
                self.assertIn("error", json.loads(response.read()))
            connection.request("POST", "/api/runs", body=b"{}",
                               headers={"Origin": "https://unrelated.example"})
            response = connection.getresponse()
            self.assertEqual(response.status, 403)
            response.read()
            connection.request("GET", "/data/runs/../../README.md")
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
            connection.request("GET", "/viewer/")
            response = connection.getresponse()
            if (demo.viewer_directory() / "index.html").is_file():
                self.assertEqual(response.status, 200)
                self.assertIn(b"index.js", response.read())
            else:
                self.assertEqual(response.status, 404)
                response.read()
            connection.request("GET", "/viewer-settings.json")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            settings = json.loads(response.read())
            self.assertEqual(settings["version"], 2)
            self.assertEqual(settings["tonemapping"], "none")
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
