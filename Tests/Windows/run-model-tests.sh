#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp/}macarchy-window-model.XXXXXX")
xcrun swiftc -swift-version 5 \
    "$repo_root/Sources/Modules/Windows/ScrollingWindowLayout.swift" \
    "$repo_root/Sources/Modules/Windows/PublicWindowIdentityResolver.swift" \
    "$repo_root/Sources/Modules/Windows/WindowMotion.swift" \
    "$repo_root/Sources/Modules/Windows/WindowPreparationPlan.swift" \
    "$repo_root/Tests/Windows/ScrollingWindowLayoutTests.swift" \
    "$repo_root/Tests/Windows/PublicWindowIdentityResolverTests.swift" \
    "$repo_root/Tests/Windows/WindowMotionTests.swift" \
    -o "$test_output/layout-tests"
"$test_output/layout-tests"
