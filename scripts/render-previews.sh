#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
python3 scripts/check_dependencies.py
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
cargo build --release --locked -p omacy-engine
mkdir -p build
xcrun swiftc -swift-version 5 -O \
  -import-objc-header crates/omacy-engine/include/omacy.h \
  tools/RenderPreviews.swift target/release/libomacy_engine.a \
  -framework AppKit -framework CoreText -framework ImageIO -framework CoreGraphics \
  -framework CoreFoundation -framework Security -liconv -lc++ -lresolv \
  -o build/RenderPreviews
build/RenderPreviews "$@"
