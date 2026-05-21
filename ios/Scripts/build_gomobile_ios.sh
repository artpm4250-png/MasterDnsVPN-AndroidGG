#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init
gomobile bind \
  -target=ios \
  -iosversion=15.0 \
  -o ios/Frameworks/MasterDnsVPNCore.xcframework \
  ./cmd/android
