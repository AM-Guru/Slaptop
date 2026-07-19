#!/usr/bin/env python3
"""Fail unless a mounted Slaptop DMG contains its expected Finder metadata."""

import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias.bookmark import kBookmarkPath


EXPECTED_ICON_LOCATIONS = {
    "Slaptop.app": (170, 210),
    "Applications": (490, 210),
}
EXPECTED_WINDOW_BOUNDS = "{{160, 120}, {660, 400}}"


def fail(message: str) -> None:
    raise SystemExit(f"DMG layout verification failed: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: verify-dmg-layout.py <mounted-dmg-path>")

    mount_path = Path(sys.argv[1])
    ds_store_path = mount_path / ".DS_Store"
    if not ds_store_path.is_file() or ds_store_path.stat().st_size == 0:
        fail(".DS_Store is missing or empty")

    try:
        with DSStore.open(str(ds_store_path), "r") as store:
            for item_name, expected_position in EXPECTED_ICON_LOCATIONS.items():
                actual_position = store[item_name]["Iloc"]
                if actual_position != expected_position:
                    fail(
                        f"{item_name} position is {actual_position!r}, "
                        f"expected {expected_position!r}"
                    )

            window_settings = store["."]["bwsp"]
            if window_settings.get("WindowBounds") != EXPECTED_WINDOW_BOUNDS:
                fail(
                    f"window bounds are {window_settings.get('WindowBounds')!r}, "
                    f"expected {EXPECTED_WINDOW_BOUNDS!r}"
                )
            if window_settings.get("ShowToolbar") is not False:
                fail("Finder toolbar must be hidden")
            if window_settings.get("ShowStatusBar") is not False:
                fail("Finder status bar must be hidden")

            icon_view_settings = store["."]["icvp"]
            if icon_view_settings.get("backgroundType") != 2:
                fail("Finder background is not configured as an image")
            if icon_view_settings.get("arrangeBy") != "none":
                fail("Finder icon auto-arrangement must be disabled")
            if icon_view_settings.get("iconSize") != 112.0:
                fail("Finder icon size is not 112 points")
            if icon_view_settings.get("textSize") != 13.0:
                fail("Finder label text size is not 13 points")
            if not icon_view_settings.get("labelOnBottom"):
                fail("Finder labels must appear below the icons")
            background_bookmark = store["."]["pBBk"]
            if background_bookmark is None:
                fail("Finder background bookmark is missing")
            if background_bookmark.get(kBookmarkPath) != [".background.png"]:
                fail("Finder background bookmark does not point to .background.png")
    except KeyError as error:
        fail(f"required Finder record {error} is missing")

    print("DMG Finder background, window, and icon positions are valid.")


if __name__ == "__main__":
    main()
