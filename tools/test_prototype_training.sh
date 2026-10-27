#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
# CPU-only prototype regression. Compiles the app's Capture/History/Training sources, then
# validates Quick defaults and the experiment manifest without constructing a Metal device.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/prototype-training.XXXXXX")
trap 'rm -rf "$work"' EXIT
cache="${TMPDIR:-/tmp}/fable-swift-cache"
T=arkit-3dgs-scanner/Training
C=arkit-3dgs-scanner/Capture
swiftc -Onone -module-cache-path "$cache" \
  $C/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
  arkit-3dgs-scanner/History/{ScanLibrary,GaussianModelImport}.swift $T/*.swift tools/test_prototype_training.swift \
  -o "$work/prototype-training"
"$work/prototype-training"
