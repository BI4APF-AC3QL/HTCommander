#!/usr/bin/env python3
"""Stage the hosted Flutter Web client into the Android asset bundle."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
WEB_BUILD = PROJECT_ROOT / "build" / "web"
ASSET_DIR = PROJECT_ROOT / "assets" / "web_app"
PLACEHOLDER = ASSET_DIR / "placeholder.txt"


def clear_staged_assets() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    for entry in ASSET_DIR.iterdir():
        if entry == PLACEHOLDER:
            continue
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()


def main() -> None:
    if sys.argv[1:] == ["--clean"]:
        clear_staged_assets()
        print(f"Cleared staged hosted web client from {ASSET_DIR}")
        return

    index = WEB_BUILD / "index.html"
    if not index.is_file():
        raise SystemExit(
            f"Missing hosted web build at {WEB_BUILD}; run flutter build web first."
        )

    clear_staged_assets()
    shutil.copytree(WEB_BUILD, ASSET_DIR, dirs_exist_ok=True)

    # The native app already carries these pubspec assets and serves them
    # directly from its asset bundle; avoid packaging a duplicate web copy.
    duplicate_assets = ASSET_DIR / "assets" / "assets"
    if duplicate_assets.exists():
        shutil.rmtree(duplicate_assets)

    # Release source maps are not needed by the browser and would inflate every
    # architecture-specific APK and the universal app bundle.
    for source_map in ASSET_DIR.rglob("*.symbols"):
        source_map.unlink()
    for source_map in ASSET_DIR.rglob("*.map"):
        source_map.unlink()

    if not (ASSET_DIR / "index.html").is_file():
        raise SystemExit("Failed to stage Android hosted web index.html.")
    print(f"Staged hosted web client into {ASSET_DIR}")


if __name__ == "__main__":
    main()
