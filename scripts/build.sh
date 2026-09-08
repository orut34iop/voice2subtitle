#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 scripts/build-metadata.py --stamp
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration "${1:-Debug}" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/app ARCHS=arm64 build
