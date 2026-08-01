#!/usr/bin/env python3
"""Collect named Maestro takeScreenshot outputs into one CI artifact directory."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil


SCREENSHOTS = ("contacts-list", "chats-list", "settings", "map")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def latest_screenshot(source: Path, name: str) -> Path:
    candidates = [
        path
        for path in source.rglob(f"{name}.png")
        if path.parent.name == "takeScreenshot"
    ]
    if not candidates:
        raise FileNotFoundError(f"Maestro did not produce takeScreenshot/{name}.png under {source}")
    return max(candidates, key=lambda path: path.stat().st_mtime_ns)


def collect(source: Path, output: Path, *, allow_missing: bool = False) -> None:
    output.mkdir(parents=True, exist_ok=True)
    for name in SCREENSHOTS:
        try:
            screenshot = latest_screenshot(source, name)
        except FileNotFoundError:
            if not allow_missing:
                raise
            print(f"missing {name}: Maestro did not reach takeScreenshot")
            continue
        if screenshot.read_bytes()[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
            raise ValueError(f"Maestro output is not a PNG: {screenshot}")
        destination = output / f"{name}.png"
        shutil.copy2(screenshot, destination)
        print(f"collected {name}: {destination} ({destination.stat().st_size} bytes)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        default=Path.home() / ".maestro" / "tests",
        help="Maestro diagnostics root (default: ~/.maestro/tests)",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="collect successful flows while the workflow reports failures separately",
    )
    args = parser.parse_args()
    collect(args.source, args.output, allow_missing=args.allow_missing)


if __name__ == "__main__":
    main()
