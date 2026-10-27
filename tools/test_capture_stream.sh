#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=$(mktemp "${TMPDIR:-/tmp}/test_capture_stream.XXXXXX")
types=$(mktemp "${TMPDIR:-/tmp}/test_capture_stream_types.XXXXXX.swift")
fixture=$(mktemp -d "${TMPDIR:-/tmp}/test_capture_stream_fixture.XXXXXX")
trap 'rm -f "$bin" "$types"; rm -rf "$fixture"' EXIT
cat > "$types" <<'EOF'
import Foundation
struct CameraIntrinsics: Codable, Sendable {
  var fx: Double; var fy: Double; var cx: Double; var cy: Double; var width: Int; var height: Int
}
EOF
swiftc -framework Foundation -framework AVFoundation -framework CoreVideo \
  "$types" "$root/arkit-3dgs-scanner/Capture/Utils.swift" \
  "$root/arkit-3dgs-scanner/Capture/CaptureStreamRecorder.swift" \
  "$root/tools/test_capture_stream.swift" -o "$bin"
"$bin" "$fixture"
python3 "$root/tools/validate_capture_package.py" "$fixture"
python3 "$root/tools/validate_capture_package.py" "$fixture/pressure"
