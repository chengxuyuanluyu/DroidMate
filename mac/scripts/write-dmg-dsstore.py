#!/usr/bin/env python3
"""Write a Finder .DS_Store for a styled installer DMG.

Programmatic .DS_Store is far more reliable than AppleScript on modern macOS
(create-dmg's AppleScript often leaves backgroundType=0 / white color).

Usage:
  write-dmg-dsstore.py <mount_point> <background.png> \\
      --app-name DroidMate.app --app-x 180 --app-y 205 \\
      --apps-x 540 --apps-y 205 --icon-size 88 \\
      --win-x 200 --win-y 120 --win-w 720 --win-h 440

Background is expected at <mount_point>/.background.png (dotfile at volume root),
matching the dmgbuild convention used for backgroundImageAlias.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("mount_point")
    p.add_argument("background", help="path to background PNG (already on volume or source to copy)")
    p.add_argument("--app-name", default="DroidMate.app")
    p.add_argument("--app-x", type=int, default=180)
    p.add_argument("--app-y", type=int, default=205)
    p.add_argument("--apps-x", type=int, default=540)
    p.add_argument("--apps-y", type=int, default=205)
    p.add_argument("--icon-size", type=float, default=88)
    p.add_argument("--text-size", type=float, default=12)
    p.add_argument("--win-x", type=int, default=200)
    p.add_argument("--win-y", type=int, default=120)
    p.add_argument("--win-w", type=int, default=720)
    p.add_argument("--win-h", type=int, default=440)
    args = p.parse_args()

    try:
        from ds_store import DSStore
        from mac_alias import Alias
    except ImportError as e:
        print(
            "error: need Python packages ds_store + mac_alias\n"
            "  python3 -m pip install ds_store mac_alias",
            file=sys.stderr,
        )
        print(f"  ({e})", file=sys.stderr)
        return 1

    mount = Path(args.mount_point)
    if not mount.is_dir():
        print(f"error: mount point not found: {mount}", file=sys.stderr)
        return 1

    # dmgbuild convention: hidden file at volume root (.background.png)
    bg_on_volume = mount / ".background.png"
    src_bg = Path(args.background)
    if src_bg.resolve() != bg_on_volume.resolve():
        bg_on_volume.write_bytes(src_bg.read_bytes())

    # Alias must point at the file on the volume (for Finder resolve)
    alias = Alias.for_file(str(bg_on_volume))
    alias_bytes = alias.to_bytes()

    # WindowBounds format: "{{x, y}, {w, h}}"
    bounds = f"{{{{{args.win_x}, {args.win_y}}}, {{{args.win_w}, {args.win_h}}}}}"

    bwsp = {
        "ShowStatusBar": False,
        "WindowBounds": bounds,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }

    # backgroundType: 0=default, 1=color, 2=picture
    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": alias_bytes,
        "backgroundColorRed": 0.08,
        "backgroundColorGreen": 0.07,
        "backgroundColorBlue": 0.16,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": float(args.text_size),
        "iconSize": float(args.icon_size),
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }

    # icvl: icon view as default
    icvl = (b"type", b"icnv")

    ds_path = mount / ".DS_Store"
    if ds_path.exists():
        ds_path.unlink()

    with DSStore.open(str(ds_path), "w+") as d:
        d["."]["vSrn"] = ("long", 1)
        d["."]["bwsp"] = bwsp
        d["."]["icvp"] = icvp
        d["."]["icvl"] = icvl
        d[args.app_name]["Iloc"] = (args.app_x, args.app_y)
        d["Applications"]["Iloc"] = (args.apps_x, args.apps_y)
        # Park utility files off-canvas so they never show as icons
        d[".background.png"]["Iloc"] = (args.win_w + 200, 100)
        vol_icon = mount / ".VolumeIcon.icns"
        if vol_icon.exists():
            d[".VolumeIcon.icns"]["Iloc"] = (args.win_w + 200, 100)

    # Hide background file from Finder icon view
    try:
        os.system(f'chflags hidden "{bg_on_volume}" 2>/dev/null')
    except Exception:
        pass
    if os.path.exists("/usr/bin/SetFile"):
        os.system(f'SetFile -a V "{bg_on_volume}" 2>/dev/null')

    size = ds_path.stat().st_size
    print(f"wrote {ds_path} ({size} bytes, backgroundType=2, icons {args.app_name}@({args.app_x},{args.app_y}) Applications@({args.apps_x},{args.apps_y}))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
