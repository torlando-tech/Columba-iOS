from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import os
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "support/collect-maestro-screenshots.py"
SPEC = spec_from_file_location("collect_maestro_screenshots", SCRIPT)
assert SPEC and SPEC.loader
MODULE = module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CollectMaestroScreenshotsTests(unittest.TestCase):
    def make_png(self, path: Path, payload: bytes = b"pixels") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(MODULE.PNG_SIGNATURE + payload)

    def test_collects_latest_named_take_screenshot_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "maestro"
            output = root / "artifact"

            for index, name in enumerate(MODULE.SCREENSHOTS):
                old = source / "old-run" / name / "takeScreenshot" / f"{name}.png"
                new = source / "new-run" / name / "takeScreenshot" / f"{name}.png"
                self.make_png(old, b"old")
                self.make_png(new, b"new")
                os.utime(old, ns=(1, 1))
                os.utime(new, ns=(index + 2, index + 2))

            MODULE.collect(source, output)

            for name in MODULE.SCREENSHOTS:
                self.assertEqual(
                    (output / f"{name}.png").read_bytes(),
                    MODULE.PNG_SIGNATURE + b"new",
                )

    def test_rejects_missing_or_non_png_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(FileNotFoundError):
                MODULE.collect(root / "missing", root / "output")

            source = root / "maestro"
            for name in MODULE.SCREENSHOTS:
                path = source / "run" / name / "takeScreenshot" / f"{name}.png"
                self.make_png(path)
            bad = source / "run" / MODULE.SCREENSHOTS[0] / "takeScreenshot" / f"{MODULE.SCREENSHOTS[0]}.png"
            bad.write_bytes(b"not a png")
            with self.assertRaises(ValueError):
                MODULE.collect(source, root / "bad-output")


if __name__ == "__main__":
    unittest.main()
