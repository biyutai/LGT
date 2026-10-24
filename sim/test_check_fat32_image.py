import io
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
from check_fat32_image import check_fat32_image


class Fat32ImageCheckTest(unittest.TestCase):
    def setUp(self):
        self.image = io.BytesIO(bytearray(8 * 512))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.refs = []
        bmp = bytearray(54)
        bmp[:2] = b'BM'
        bmp[2:6] = (54).to_bytes(4, 'little')
        bmp[18:22] = (640).to_bytes(4, 'little')
        bmp[22:26] = (480).to_bytes(4, 'little')
        bmp[28:30] = (24).to_bytes(2, 'little')
        wav = bytearray(1068)
        wav[:4] = b'RIFF'
        wav[4:8] = (1060).to_bytes(4, 'little')
        wav[8:16] = b'WAVEfmt '
        wav[20:22] = (1).to_bytes(2, 'little')
        wav[22:24] = (2).to_bytes(2, 'little')
        wav[24:28] = (48000).to_bytes(4, 'little')
        wav[34:36] = (16).to_bytes(2, 'little')
        wav[36:40] = b'data'
        wav[40:44] = (1024).to_bytes(4, 'little')
        self.write(0, 0, b'\xeb')
        self.write(0, 11, (512).to_bytes(2, 'little'))
        self.write(0, 13, b'\x01')
        self.write(0, 14, b'\x01\x00')
        self.write(0, 16, b'\x01')
        self.write(0, 36, (1).to_bytes(4, 'little'))
        self.write(0, 44, (2).to_bytes(4, 'little'))
        self.write(0, 510, b'\x55\xaa')
        for cluster, next_cluster in ((2, 7), (3, 0x0fffffff),
                                      (4, 5), (5, 6), (6, 0x0fffffff),
                                      (7, 0x0fffffff)):
            self.write(1, cluster * 4, next_cluster.to_bytes(4, 'little'))
        for entry in range(16):
            self.write(2, entry * 32, b'X')
        self.entry(7, 0, b'PIC1    BMP', 3, len(bmp))
        self.entry(7, 32, b'MUSIC   WAV', 4, len(wav))
        self.write(3, 0, bmp)
        for offset, cluster in ((0, 4), (512, 5), (1024, 6)):
            self.write(cluster, 0, wav[offset:offset + 512])
        for name, data in (('pic.bmp', bmp), ('music.wav', wav)):
            path = pathlib.Path(self.temp.name) / name
            path.write_bytes(data)
            self.refs.append(path)

    def write(self, sector, offset, data):
        self.image.seek(sector * 512 + offset)
        self.image.write(data)

    def entry(self, sector, offset, name, cluster, size):
        self.write(sector, offset, name)
        self.write(sector, offset + 11, b'\x20')
        self.write(sector, offset + 26, cluster.to_bytes(2, 'little'))
        self.write(sector, offset + 28, size.to_bytes(4, 'little'))

    def test_root_chain_and_file_chain(self):
        self.assertTrue(check_fat32_image(self.image, self.refs))

    def test_broken_file_chain(self):
        self.write(1, 4 * 4, (0x0fffffff).to_bytes(4, 'little'))
        self.assertFalse(check_fat32_image(self.image, self.refs))


if __name__ == '__main__':
    unittest.main()
