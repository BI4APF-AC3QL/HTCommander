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
PUBSPEC = PROJECT_ROOT / "pubspec.yaml"
PUBSPEC_BACKUP = PROJECT_ROOT / ".dart_tool" / "htcommander-android-pubspec.yaml"


def restore_package_manifest() -> None:
    if not PUBSPEC_BACKUP.is_file():
        return
    PUBSPEC.write_bytes(PUBSPEC_BACKUP.read_bytes())
    PUBSPEC_BACKUP.unlink()


def prepare_package_manifest() -> None:
    """Declare every generated web subdirectory as a Flutter asset directory.

    Flutter's pubspec directory entries include files immediately within that
    directory, but do not recursively include nested directories. The staged
    web client has a generated tree (CanvasKit, package assets, etc.), so the
    Android application bundle needs explicit entries for each directory.
    Keep this change temporary so the checked-in pubspec stays stable.
    """
    if not (ASSET_DIR / "index.html").is_file():
        raise SystemExit(f"No staged web client found at {ASSET_DIR}.")

    restore_package_manifest()
    original_bytes = PUBSPEC.read_bytes()
    original = original_bytes.decode("utf-8")
    newline = "\r\n" if "\r\n" in original else "\n"
    marker = f"    - assets/web_app/{newline}"
    if original.count(marker) != 1:
        raise SystemExit("Could not find the unique assets/web_app entry in pubspec.yaml.")

    asset_dirs = sorted(
        path.relative_to(PROJECT_ROOT).as_posix() + "/"
        for path in ASSET_DIR.rglob("*")
        if path.is_dir()
    )
    additions = "".join(f"    - {directory}{newline}" for directory in asset_dirs)
    PUBSPEC_BACKUP.parent.mkdir(parents=True, exist_ok=True)
    PUBSPEC_BACKUP.write_bytes(original_bytes)
    PUBSPEC.write_bytes(original.replace(marker, marker + additions).encode("utf-8"))
    print(f"Temporarily declared {len(asset_dirs)} nested hosted web asset directories")


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
    if sys.argv[1:] == ["--restore-package"]:
        restore_package_manifest()
        print("Restored pubspec.yaml after Android packaging")
        return
    if sys.argv[1:] == ["--prepare-package"]:
        prepare_package_manifest()
        return
    if sys.argv[1:] == ["--clean"]:
        restore_package_manifest()
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
