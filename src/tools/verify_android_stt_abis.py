#!/usr/bin/env python3
"""Check that packaged Android speech-recognition libraries match runtime ABI checks."""

from __future__ import annotations

import sys
from pathlib import Path
from zipfile import BadZipFile, ZipFile


REQUIRED_SHERPA_LIBRARIES = {
    "libonnxruntime.so",
    "libsherpa-onnx-c-api.so",
    "libsherpa-onnx-cxx-api.so",
}
EXPECTED_PACKAGES = {
    "app-arm64-v8a-release.apk": ("arm64-v8a", True),
    "app-armeabi-v7a-release.apk": ("armeabi-v7a", False),
    "app-x86_64-release.apk": ("x86_64", True),
}


def verify(package_dir: Path) -> None:
    for package_name, (abi, has_sherpa_fallback) in EXPECTED_PACKAGES.items():
        package = package_dir / package_name
        if not package.is_file():
            raise SystemExit(f"Missing Android package: {package}")

        try:
            with ZipFile(package) as archive:
                bad_member = archive.testzip()
                if bad_member is not None:
                    raise SystemExit(f"Corrupt member {bad_member} in {package}")
                native_libraries = {
                    Path(name).name
                    for name in archive.namelist()
                    if name.startswith(f"lib/{abi}/") and name.endswith(".so")
                }
        except BadZipFile as error:
            raise SystemExit(f"Invalid APK archive {package}: {error}") from error

        sherpa_libraries = native_libraries & REQUIRED_SHERPA_LIBRARIES
        if has_sherpa_fallback:
            missing = REQUIRED_SHERPA_LIBRARIES - sherpa_libraries
            if missing:
                raise SystemExit(
                    f"{package_name} is marked as supporting Sherpa fallback, "
                    f"but is missing: {', '.join(sorted(missing))}"
                )
        elif sherpa_libraries:
            raise SystemExit(
                f"{package_name} has no Sherpa fallback in the runtime capability "
                f"check but unexpectedly bundles: {', '.join(sorted(sherpa_libraries))}"
            )

        state = "Sherpa offline fallback included" if has_sherpa_fallback else (
            "system recognizer only; no Sherpa fallback"
        )
        print(f"{package_name}: {abi}, {state}")


if __name__ == "__main__":
    directory = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        "build/app/outputs/flutter-apk"
    )
    verify(directory)
