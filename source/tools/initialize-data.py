#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Copy missing public examples into a checkout's private data directories, offline."""
import json
from pathlib import Path


def initialize(root):
    root = Path(root).resolve()
    copied = 0
    for directory in ["manifests", "profiles"]:
        target = root / directory
        if target.is_symlink():
            raise ValueError("Data directories must not be symbolic links")
        target.mkdir(exist_ok=True)
        for example in sorted((root / "examples" / directory).glob("*.json")):
            json.loads(example.read_text())
            destination = target / example.name
            if destination.is_symlink():
                raise ValueError("Existing data files must not be symbolic links")
            if not destination.exists():
                with destination.open("xb") as handle:
                    handle.write(example.read_bytes())
                copied += 1
    for directory in ["logs", "tmp", "cache", "downloads", "runtimes", "toolchains", "prefixes", "backups"]:
        target = root / directory
        if target.is_symlink():
            raise ValueError("Data directories must not be symbolic links")
        target.mkdir(exist_ok=True)
    return copied


if __name__ == "__main__":
    count = initialize(Path(__file__).resolve().parents[2])
    print(f"Copied {count} missing examples. Existing data was preserved. No software was downloaded or launched.")
