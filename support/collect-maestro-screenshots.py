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


def collect(source: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    for name in SCREENSHOTS:
        screenshot = latest_screenshot(source, name)
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
    args = parser.parse_args()
    collect(args.source, args.output)


if __name__ == "__main__":
    main()
