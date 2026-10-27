#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
# CPU math only; native RealityKit resource creation requires the iOS 27 SDK and a device.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/reality-viewer.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc arkit-3dgs-scanner/Training/GaussianRealityKitViewer.swift \
  tools/test_gaussian_reality_viewer.swift -o "$work/test"
"$work/test"
