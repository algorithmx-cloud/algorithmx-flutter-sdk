#!/usr/bin/env python3
"""Keep the bundled native SDK source identical to the sibling native SDKs.

The Flutter plugin must be installable by itself, so it compiles copies of the
Android and iOS source. This script prevents those copies from silently drifting
from the native SDKs in this monorepo. It intentionally does not merge the
Android manifest: the plugin's manifest also declares its own plugin package,
so review manifest changes by hand when the native SDK changes.

Run from anywhere:
    python3 platforms/flutter/flutter-sdk/tool/sync_native_sdks.py --check
    python3 platforms/flutter/flutter-sdk/tool/sync_native_sdks.py --sync
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[3]
PLUGIN = REPO / "flutter/flutter-sdk"

# The Android bridge lives in the sibling `flutter` package. It is intentionally
# excluded when we compare the copied AlgorithmX Kotlin tree.
TREES = (
    (
        REPO / "android/android-sdk/src/main/java/algorithmx/engage",
        PLUGIN / "android/src/main/kotlin/algorithmx/engage",
        {"flutter"},
    ),
    (
        REPO / "android/android-sdk/src/main/res",
        PLUGIN / "android/src/main/res",
        set(),
    ),
    (
        REPO / "ios/ios-sdk/Sources/AlgorithmXSDK",
        PLUGIN / "ios/algorithmx_flutter/Sources/algorithmx_flutter/NativeSDK",
        set(),
    ),
)


def files_below(root: Path, protected: set[str]) -> dict[Path, Path]:
    """Index relative file paths, ignoring a bridge-owned top-level folder."""
    if not root.is_dir():
        raise FileNotFoundError(f"Native source directory is missing: {root}")
    return {
        path.relative_to(root): path
        for path in root.rglob("*")
        if path.is_file() and path.relative_to(root).parts[0] not in protected
    }


def sync_or_check(sync: bool) -> int:
    differences: list[str] = []
    for original, bundled, protected in TREES:
        source_files = files_below(original, set())
        bundled.mkdir(parents=True, exist_ok=True)
        bundled_files = files_below(bundled, protected)

        for relative, source in source_files.items():
            destination = bundled / relative
            if not destination.is_file() or source.read_bytes() != destination.read_bytes():
                differences.append(str(destination.relative_to(REPO)))
                if sync:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)

        for relative, old_file in bundled_files.items():
            if relative not in source_files:
                differences.append(str(old_file.relative_to(REPO)))
                if sync:
                    old_file.unlink()

    if differences:
        verb = "Synchronized" if sync else "Native source differs at"
        print(f"{verb} {len(differences)} file(s):")
        for path in differences:
            print(f"  {path}")
        if not sync:
            print("Run with --sync, then review the changes and Android manifest.")
            return 1
    else:
        print("Bundled Android and iOS source matches the native SDKs.")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true", help="Report source drift")
    action.add_argument("--sync", action="store_true", help="Copy native SDK changes")
    args = parser.parse_args()
    try:
        sys.exit(sync_or_check(sync=args.sync))
    except FileNotFoundError as error:
        parser.error(str(error))
