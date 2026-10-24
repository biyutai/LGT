import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_wav import FS, demo, demo_beat


class DemoBeatTest(unittest.TestCase):
    def test_beat_is_soft_low_frequency_without_tone(self):
        original = demo() * 0.72
        mixed = demo_beat()
        self.assertEqual(mixed.shape, (12 * FS, 2))
        residual = mixed[:, 0] - original[:, 0]
        self.assertLess(np.max(np.abs(residual[int(0.2 * FS):int(0.45 * FS)])), 1e-10)

        beat = residual[FS // 2:FS // 2 + int(0.18 * FS)]
        spectrum = np.abs(np.fft.rfft(beat)) ** 2
        frequency = np.fft.rfftfreq(len(beat), 1 / FS)
        bass_energy = spectrum[(frequency >= 30) & (frequency <= 250)].sum()
        high_energy = spectrum[(frequency >= 3000) & (frequency <= 6000)].sum()
        self.assertGreater(bass_energy, 0)
        self.assertLess(high_energy / bass_energy, 1e-4)
        self.assertLess(abs(beat[0]), 1e-10)


if __name__ == "__main__":
    unittest.main()
