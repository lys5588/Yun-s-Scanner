#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
"""Validate the continuous capture contract without NumPy or training dependencies.

By default ffprobe decodes video frame headers and checks every recorded PTS and
image size. --skip-video-decode only checks the metadata and binary payloads; its
report explicitly says that the movies were not verified.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys


class InvalidCapture(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidCapture(message)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def load_json(path):
    def invalid_constant(value):
        raise InvalidCapture(f"{path.name}: nonfinite JSON value {value}")
    return json.loads(path.read_text(), parse_constant=invalid_constant)


def load_lines(path):
    def invalid_constant(value):
        raise InvalidCapture(f"{path.name}: nonfinite JSON value {value}")
    with path.open() as handle:
        for line_number, line in enumerate(handle, 1):
            if line.strip():
                try:
                    row = json.loads(line, parse_constant=invalid_constant)
                except (json.JSONDecodeError, InvalidCapture) as error:
                    raise InvalidCapture(f"{path.name}:{line_number}: {error}") from error
                require(isinstance(row, dict), f"{path.name}:{line_number}: expected object")
                yield row


def local_file(root, relative):
    require(isinstance(relative, str) and bool(relative), "Missing relative file path")
    target = (root / relative).resolve()
    require(not Path(relative).is_absolute() and target.is_relative_to(root),
            f"File escapes capture directory: {relative}")
    require(target.is_file(), f"Missing file: {relative}")
    return target


def check_camera(row, label):
    k = row.get("intrinsics", {})
    require(isinstance(k, dict), f"{label}: missing intrinsics")
    for name in ("fx", "fy", "cx", "cy", "width", "height"):
        require(finite(k.get(name)), f"{label}: invalid intrinsic {name}")
    require(k["fx"] > 0 and k["fy"] > 0 and k["width"] > 0 and k["height"] > 0,
            f"{label}: nonpositive focal length or image size")
    require(int(k["width"]) == k["width"] and int(k["height"]) == k["height"],
            f"{label}: noninteger image size")
    matrix = row.get("transform")
    require(isinstance(matrix, list) and len(matrix) == 16 and all(map(finite, matrix)),
            f"{label}: expected finite row-major 4x4 camera-to-world transform")
    require(max(abs(matrix[12 + i] - (1 if i == 3 else 0)) for i in range(4)) < 1e-4,
            f"{label}: invalid homogeneous transform row")
    rotation = [[matrix[r * 4 + c] for c in range(3)] for r in range(3)]
    for r in range(3):
        for c in range(3):
            dot = sum(rotation[r][i] * rotation[c][i] for i in range(3))
            require(abs(dot - (1 if r == c else 0)) < 2e-3,
                    f"{label}: rotation is not orthonormal")
    a, b, c = rotation
    determinant = (a[0] * (b[1] * c[2] - b[2] * c[1])
                   - a[1] * (b[0] * c[2] - b[2] * c[0])
                   + a[2] * (b[0] * c[1] - b[1] * c[0]))
    require(abs(determinant - 1) < 2e-3, f"{label}: reflected camera rotation")


def inspect_video(path):
    executable = shutil.which("ffprobe")
    require(executable is not None,
            "ffprobe is required for movie verification; install ffmpeg or explicitly use --skip-video-decode")
    result = subprocess.run(
        [executable, "-v", "error", "-select_streams", "v:0", "-show_frames",
         "-show_entries", "frame=best_effort_timestamp_time,width,height", "-of", "json", str(path)],
        capture_output=True, text=True, check=False)
    require(result.returncode == 0 and not result.stderr.strip(),
            f"{path.name}: video decode failed: {result.stderr.strip()}")
    return json.loads(result.stdout).get("frames", [])


def validate(root, decode_video=True):
    root = root.resolve()
    metadata = load_json(root / "capture-meta.json")
    stream = metadata.get("streamCapture")
    require(isinstance(stream, dict) and stream.get("schemaVersion") == 1,
            "Missing continuous stream schema version 1")
    require(stream.get("status") == "complete",
            f"Capture stream is not complete: {stream.get('status', 'missing status')}; "
            f"{stream.get('failure') or 'stop recording and wait for file finalization'}")
    manifest = local_file(root, stream.get("manifestFile"))
    rows = list(load_lines(manifest))
    require(rows, "Continuous frame manifest is empty")
    movies = defaultdict(list)
    timestamp_to_frame = {}
    previous_id, previous_timestamp = -1, -math.inf
    depth_count, dropped_count = 0, 0
    for row in rows:
        frame_id = row.get("frameID")
        label = f"frame {frame_id}"
        require(type(frame_id) is int and frame_id > previous_id, f"{label}: frame IDs must increase")
        timestamp = row.get("timestamp")
        require(finite(timestamp) and timestamp > previous_timestamp, f"{label}: timestamps must increase")
        previous_id, previous_timestamp = frame_id, timestamp
        timestamp_to_frame[timestamp] = row
        check_camera(row, label)
        require(isinstance(row.get("trackingState"), str), f"{label}: missing tracking state")
        require(type(row.get("videoWritten")) is bool, f"{label}: missing video write outcome")
        if row["videoWritten"]:
            pts = row.get("videoPTS")
            require(finite(pts) and pts >= 0, f"{label}: invalid movie PTS")
            local_file(root, row.get("videoFile"))
            movies[row["videoFile"]].append(row)
            require(not row.get("dropReason"), f"{label}: written video frame has a drop reason")
        else:
            dropped_count += 1
            require(isinstance(row.get("dropReason"), str) and bool(row["dropReason"]),
                    f"{label}: dropped video frame lacks a reason")
        if row.get("depthFile"):
            width, height = row.get("depthWidth"), row.get("depthHeight")
            require(type(width) is int and type(height) is int and width > 0 and height > 0,
                    f"{label}: invalid depth dimensions")
            depth = local_file(root, row["depthFile"])
            require(depth.stat().st_size == width * height * 4,
                    f"{label}: Float32 depth byte length does not match dimensions")
            depth_count += 1
            if row.get("confidenceFile"):
                confidence = local_file(root, row["confidenceFile"]).read_bytes()
                require(len(confidence) == width * height, f"{label}: confidence byte length mismatch")
                require(all(value <= 2 for value in confidence), f"{label}: confidence outside ARKit range 0–2")
        else:
            require(not row.get("confidenceFile"), f"{label}: confidence without depth")

    require(movies, "No successfully written video frames")
    declared = stream.get("videoSegments")
    require(isinstance(declared, list) and len(declared) == len(set(declared)),
            "Invalid or duplicate video segment list")
    require(set(movies) == set(declared),
            "Video segment list differs from successfully written frames (missing or empty segment)")
    for relative in declared:
        local_file(root, relative)
    for movie, records in movies.items():
        pts = [record["videoPTS"] for record in records]
        require(all(b > a for a, b in zip(pts, pts[1:])), f"{movie}: nonmonotonic movie PTS")
        # One clock offset per segment; neither dropped frames nor pauses may compress time.
        offsets = [record["timestamp"] - record["videoPTS"] for record in records]
        require(max(offsets) - min(offsets) <= 0.002, f"{movie}: PTS drift from ARFrame timestamps")
        if decode_video:
            decoded = inspect_video(local_file(root, movie))
            require(len(decoded) == len(records),
                    f"{movie}: decoded frame count {len(decoded)} differs from manifest {len(records)}")
            for actual, expected in zip(decoded, records):
                require("best_effort_timestamp_time" in actual, f"{movie}: decoded frame missing PTS")
                require(abs(float(actual["best_effort_timestamp_time"]) - expected["videoPTS"]) <= 0.002,
                        f"{movie}: decoded PTS differs from manifest")
                require((actual["width"], actual["height"]) ==
                        (expected["intrinsics"]["width"], expected["intrinsics"]["height"]),
                        f"{movie}: video dimensions differ from the calibration")

    keyframes = list(load_lines(root / "poses.jsonl")) if (root / "poses.jsonl").exists() else []
    ids = set()
    for keyframe in keyframes:
        label = f"keyframe {keyframe.get('id')}"
        require(keyframe.get("id") not in ids, f"{label}: duplicate keyframe ID")
        ids.add(keyframe.get("id"))
        check_camera(keyframe, label)
        local_file(root, "images/" + keyframe["imageFile"])
        timestamp = keyframe.get("timestamp")
        require(finite(timestamp), f"{label}: invalid timestamp")
        matching = timestamp_to_frame.get(timestamp)
        if matching is None:
            matching = next((row for ts, row in timestamp_to_frame.items() if abs(ts - timestamp) < 1e-6), None)
        require(matching is not None, f"{label}: no corresponding continuous frame")
        require(keyframe["intrinsics"] == matching["intrinsics"], f"{label}: calibration differs from its ARFrame")
        require(max(abs(a - b) for a, b in zip(keyframe["transform"], matching["transform"])) < 1e-5,
                f"{label}: capture pose differs from its ARFrame")

    return {"frames": len(rows), "videoFrames": len(rows) - dropped_count,
            "droppedVideoFrames": dropped_count, "depthFrames": depth_count,
            "keyframes": len(keyframes), "videoSegments": len(movies),
            "videoDecoded": decode_video}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scan", type=Path)
    parser.add_argument("--skip-video-decode", action="store_true")
    args = parser.parse_args()
    try:
        report = validate(args.scan, decode_video=not args.skip_video_decode)
    except (InvalidCapture, OSError, ValueError, TypeError, KeyError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    print("PASS: capture package verified" if report["videoDecoded"]
          else "PARTIAL: metadata and payloads checked; video decoding was explicitly skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
