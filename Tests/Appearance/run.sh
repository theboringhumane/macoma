#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
appearance_test_dir=$(mktemp -d -t macarchy-appearance)
trap 'rm -rf "$appearance_test_dir"' EXIT
xcrun swiftc -swift-version 6 Sources/Modules/Appearance/*.swift Tests/Appearance/AppearanceTests.swift -o "$appearance_test_dir/appearance-tests"
"$appearance_test_dir/appearance-tests" "$PWD" "$@"
