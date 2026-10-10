#!/bin/bash
set -euo pipefail
terminal_test_root=$(cd "$(dirname "$0")/../.." && pwd)
terminal_test_build=$(mktemp -d /tmp/macarchy-terminal-test-build.XXXXXX)
trap 'rm -rf "$terminal_test_build"' EXIT
ghostty_binary=${GHOSTTY_BINARY:-/Applications/Ghostty.app/Contents/MacOS/ghostty}
tmux_binary=${TMUX_BINARY:-/opt/homebrew/bin/tmux}
if [[ ! -x "$ghostty_binary" || ! -x "$tmux_binary" ]]; then
  echo "Terminal qualification requires an installed Ghostty and tmux. Set GHOSTTY_BINARY and TMUX_BINARY if needed." >&2
  exit 1
fi
xcrun swiftc -swift-version 5 -parse-as-library \
  "$terminal_test_root/Sources/Modules/Terminal/TerminalProfile.swift" \
  "$terminal_test_root/Tests/Terminal/TerminalTests.swift" \
  -o "$terminal_test_build/TerminalTests"
"$terminal_test_build/TerminalTests" "$terminal_test_root/Resources/Terminal" "$ghostty_binary" "$tmux_binary"
