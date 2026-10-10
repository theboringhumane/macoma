#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_BUILD_DIR="$PROJECT_ROOT/build/tests"
mkdir -p "$TEST_BUILD_DIR"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -framework AppKit -framework ScreenSaver \
  -parse-as-library "$PROJECT_ROOT/Tests/SaverHost/SaverHostSmoke.swift" \
  -o "$TEST_BUILD_DIR/SaverHostSmoke"
exec "$TEST_BUILD_DIR/SaverHostSmoke" "$@"
