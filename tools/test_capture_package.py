#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""Exercise the capture validator against a real encoded movie and damaged packages."""
import copy
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

from validate_capture_package import InvalidCapture, validate


class CapturePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "depth" / "continuous").mkdir(parents=True)
        (self.root / "images").mkdir()
        self.meta = {"streamCapture": {
            "schemaVersion": 1, "manifestFile": "frames.jsonl",
            "status": "complete", "videoSegments": ["color.mov"]}}
        self.rows = []
        for index in range(2):
            self.rows.append({
                "frameID": index, "timestamp": 100 + index / 30, "videoPTS": index / 30,
                "videoFile": "color.mov", "videoWritten": True, "trackingState": "normal",
                "intrinsics": {"fx": 12.0, "fy": 12.0, "cx": 8.0, "cy": 8.0, "width": 16, "height": 16},
                "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                "depthFile": f"depth/continuous/{index}.f32",
                "confidenceFile": f"depth/continuous/{index}.u8", "depthWidth": 2, "depthHeight": 2})
            (self.root / self.rows[-1]["depthFile"]).write_bytes(struct.pack("<4f", 1, 2, 3, 4))
            (self.root / self.rows[-1]["confidenceFile"]).write_bytes(bytes([2, 2, 1, 0]))
        (self.root / "color.mov").write_bytes(b"metadata-only-placeholder")
        self.write()

    def tearDown(self):
        self.temporary.cleanup()

    def write(self):
        (self.root / "capture-meta.json").write_text(json.dumps(self.meta))
        (self.root / "frames.jsonl").write_text("".join(json.dumps(row) + "\n" for row in self.rows))

    def check_invalid(self, message):
        self.write()
        with self.assertRaisesRegex(InvalidCapture, message):
            validate(self.root, decode_video=False)

    def test_payloads_only_is_explicitly_partial(self):
        report = validate(self.root, decode_video=False)
        self.assertFalse(report["videoDecoded"])
        self.assertEqual(report["depthFrames"], 2)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg/ffprobe required")
    def test_real_movie_matches_and_detects_wrong_pts(self):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                        "color=c=red:s=16x16:r=30", "-frames:v", "2", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", str(self.root / "color.mov")], check=True)
        self.assertTrue(validate(self.root)["videoDecoded"])
        # Preserve the per-segment clock offset, but lie about both the camera time
        # and stored PTS of one frame. Only an actual movie check detects this.
        self.rows[1]["videoPTS"] += 0.01
        self.rows[1]["timestamp"] += 0.01
        self.write()
        with self.assertRaisesRegex(InvalidCapture, "decoded PTS"):
            validate(self.root)

    def test_truncated_depth(self):
        (self.root / self.rows[0]["depthFile"]).write_bytes(b"\x00" * 12)
        self.check_invalid("depth byte length")

    def test_bad_confidence(self):
        (self.root / self.rows[0]["confidenceFile"]).write_bytes(bytes([2, 3, 1, 0]))
        self.check_invalid("confidence outside")

    def test_timestamp_and_frame_id_order(self):
        self.rows[1]["timestamp"] = self.rows[0]["timestamp"]
        self.check_invalid("timestamps must increase")
        self.rows[1]["timestamp"] += 1
        self.rows[1]["frameID"] = self.rows[0]["frameID"]
        self.check_invalid("frame IDs must increase")

    def test_drops_have_explicit_reason(self):
        self.rows[1]["videoWritten"] = False
        self.check_invalid("lacks a reason")
        self.rows[1]["dropReason"] = "writer_backpressure"
        self.write()
        self.assertEqual(validate(self.root, decode_video=False)["droppedVideoFrames"], 1)

    def test_escaping_file_reference(self):
        self.rows[0]["depthFile"] = "../not-a-capture-file"
        self.check_invalid("escapes capture")

    def test_camera_reflection_and_wrong_matrix_layout(self):
        self.rows[0]["transform"][0] = -1
        self.check_invalid("reflected")
        self.rows[0]["transform"][0] = 1
        self.rows[0]["transform"][12] = 3
        self.check_invalid("homogeneous")

    def test_keyframe_correspondence(self):
        record = copy.deepcopy(self.rows[0])
        record["id"] = 1
        record["imageFile"] = "001.jpg"
        (self.root / "images" / "001.jpg").write_bytes(b"preserved-keyframe")
        (self.root / "poses.jsonl").write_text(json.dumps(record) + "\n")
        self.assertEqual(validate(self.root, decode_video=False)["keyframes"], 1)
        record["intrinsics"]["fx"] += 1
        (self.root / "poses.jsonl").write_text(json.dumps(record) + "\n")
        with self.assertRaisesRegex(InvalidCapture, "calibration differs"):
            validate(self.root, decode_video=False)

    def test_nonfinite_json_is_rejected(self):
        self.rows[0]["timestamp"] = float("nan")
        self.check_invalid("nonfinite JSON")

    def test_incomplete_or_failed_recording_is_not_success(self):
        for status in ("recording", "failed"):
            self.meta["streamCapture"]["status"] = status
            self.check_invalid("not complete")

    def test_declared_empty_segment_is_rejected(self):
        self.meta["streamCapture"]["videoSegments"].append("color-0001.mov")
        (self.root / "color-0001.mov").write_bytes(b"empty-movie")
        self.check_invalid("empty segment")

    def test_resume_keeps_separate_movie_clocks(self):
        self.rows[1]["videoFile"] = "color-0001.mov"
        self.rows[1]["videoPTS"] = 0
        self.rows[1]["timestamp"] = 130
        (self.root / "color-0001.mov").write_bytes(b"second-segment")
        self.meta["streamCapture"]["videoSegments"].append("color-0001.mov")
        self.write()
        self.assertEqual(validate(self.root, decode_video=False)["videoSegments"], 2)


if __name__ == "__main__":
    unittest.main()
