"""The single-card package must start quickly and include both demo tracks."""
import pathlib
import unittest

import package_content


ROOT = pathlib.Path(__file__).resolve().parents[1]


class SingleCardPackageTest(unittest.TestCase):
    def test_native_first_and_all_demo_tracks(self):
        items, errors, warnings = package_content.collect(ROOT / "assets" / "scale_demo")
        self.assertEqual(errors, [])
        self.assertEqual([item.path.name for item in items if item.kind == "BMP"][0],
                         "02_forest_640x480.bmp")
        self.assertEqual([item.path.name for item in items if item.kind == "WAV"],
                         ["05_demo_beat.wav", "06_demo_melody.wav"])
        self.assertNotIn("TEXT", [item.kind for item in items])
        self.assertFalse(any("2 WAVs found" in warning for warning in warnings))


if __name__ == "__main__":
    unittest.main()
