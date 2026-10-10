#!/usr/bin/env python3
"""Check that the pinned ttfx source and required notices are present."""
from pathlib import Path


def require_dependencies(project_root):
    required = ("Cargo.toml", "src/lib.rs", "LICENSE", "NOTICE")
    dependency = Path(project_root) / "vendor/ttfx"
    if any(not (dependency / name).is_file() for name in required):
        raise SystemExit(
            "The ttfx submodule is missing or incomplete.\n"
            "From the repository root, run:\n"
            "  git submodule update --init --recursive\n"
            "Then rerun this command."
        )


if __name__ == "__main__":
    require_dependencies(Path(__file__).resolve().parent.parent)
