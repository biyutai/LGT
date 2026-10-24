import struct
import unittest

from check_tf_image import supported_bmp_header


class BmpHeaderTest(unittest.TestCase):
    def header(self, width, height, depth=24, compression=0):
        data = bytearray(64)
        data[:2] = b"BM"
        struct.pack_into("<II", data, 18, width, height)
        struct.pack_into("<H", data, 28, depth)
        struct.pack_into("<I", data, 30, compression)
        return bytes(data)

    def test_supported_sizes_and_format(self):
        self.assertTrue(supported_bmp_header(self.header(640, 480)))
        self.assertTrue(supported_bmp_header(self.header(320, 240)))
        self.assertTrue(supported_bmp_header(self.header(1280, 960)))
        self.assertTrue(supported_bmp_header(self.header(320, 180)))
        self.assertFalse(supported_bmp_header(self.header(800, 600)))
        self.assertFalse(supported_bmp_header(self.header(320, 240, depth=32)))
        self.assertFalse(supported_bmp_header(self.header(320, 240, compression=1)))
        self.assertFalse(supported_bmp_header(self.header(320, 0xFFFF_FF10)))


if __name__ == "__main__":
    unittest.main()
