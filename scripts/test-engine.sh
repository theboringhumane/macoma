#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
python3 "$project_dir/scripts/check_dependencies.py"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
qualification_dir="$project_dir/target/qualification"
mkdir -p "$qualification_dir"

# Session API calls require the OS main thread; cargo test alone cannot
# exercise that FFI path on macOS. Keep the native C executables below.
cargo test --locked -p omacy-engine --lib -- --nocapture 2>&1 | tee "$qualification_dir/rust-tests.log"
cargo build --locked -p omacy-engine

case "$(uname -s)" in
  Darwin) native_libraries=(-framework CoreFoundation -framework Security -liconv -lSystem) ;;
  Linux) native_libraries=(-ldl -lpthread -lm) ;;
  *) printf 'Unsupported qualification host: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac

for contract in abi_header_layout abi_previous_declaration catalog_lifecycle; do
  cc -std=c11 -Wall -Wextra -Werror -pedantic \
    -I crates/omacy-engine/include \
    "crates/omacy-engine/tests/$contract.c" \
    target/debug/libomacy_engine.a "${native_libraries[@]}" \
    -o "$qualification_dir/$contract"
  "$qualification_dir/$contract" | tee "$qualification_dir/$contract.log"
  printf 'PASS native C contract: %s\n' "$contract"
done

c++ -x c++ -std=c++17 -Wall -Wextra -Werror -pedantic \
  -I crates/omacy-engine/include -fsyntax-only \
  crates/omacy-engine/tests/abi_header_layout.c
printf 'PASS C++ header layout\n'
printf 'Qualification evidence: %s\n' "$qualification_dir"
