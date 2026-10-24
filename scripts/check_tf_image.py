"""按 FPGA 的 FAT32/原始扇区规则检查 TF 卡镜像与电脑文件是否一致。

用法：python scripts/check_tf_image.py 整卡.img [对照文件 ...]
FAT32 镜像需包含目录、FAT 表和文件数据；旧版原始布局只需前 64MB。
镜像可用管理员权限从 \\\\.\\PhysicalDriveN 读取；FAT32 需读取整个分区。

旧版原始布局照 user_source/hdl_source/SD/bmp_read.v 的 ST_SCAN 逻辑走一遍：
    从扇区 0 起逐扇区看文件头：
      BMP：'BM' + 320×180 / 320×240 / 640×480 / 1280×960 + 24 位 + 无压缩 → 登记（最多 4 张），按文件长度跳过
      WAV：RIFF/WAVE/16 字节 fmt PCM/2 声道/48000Hz/16 位/data，样本 >= 256 → 只记第一个，按文件长度跳过
    结束：BMP 后扫到 WAV；或 4 张 BMP 齐了且 WAV 已找到；或齐了之后连续 1024 个扇区没有新东西；或扫到第 131071 扇区
"""
import hashlib
import pathlib
import struct
import sys

from check_fat32_image import check_fat32_image

SCAN_MAX = 131071
TARGET = 4
GAP = 1024
WAV_MAX_WORDS = 1329152


def u16(b, o): return struct.unpack_from('<H', b, o)[0]
def u32(b, o): return struct.unpack_from('<I', b, o)[0]


def supported_bmp_header(header):
    if len(header) < 34 or header[:2] != b'BM':
        return False
    width, height = u32(header, 18), u32(header, 22)
    return ((width, height) in ((640, 480), (320, 240), (320, 180), (1280, 960))
            and u16(header, 28) == 24 and u32(header, 30) == 0)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(sys.argv[1], 'rb') as image:
        fat32_result = check_fat32_image(image, sys.argv[2:])
    if fat32_result is not None:
        sys.exit(0 if fat32_result else 1)
    with open(sys.argv[1], 'rb') as image:
        img = image.read((SCAN_MAX + 1) * 512)
    refs = {}
    for f in sys.argv[2:]:
        d = pathlib.Path(f).read_bytes()
        refs[hashlib.sha256(d).hexdigest()] = (pathlib.Path(f).name, d)

    def name_of(off, length):
        if off + length > len(img):
            return '(超出镜像)'
        h = hashlib.sha256(img[off:off + length]).hexdigest()
        return refs[h][0] if h in refs else '(内容与对照文件都不一致)'

    s = 0
    bmps = []
    wav = None
    reached = False
    gap = 0
    while True:
        o = s * 512
        b = img[o:o + 64]
        if len(b) < 44:
            print(f'镜像在扇区 {s} 截断，无法完成原始扇区检查')
            print('VERIFY FAIL')
            sys.exit(1)
        bmp_hit = supported_bmp_header(b)
        wav_hit = (b[0:4] == b'RIFF' and b[8:12] == b'WAVE' and b[12:16] == b'fmt ' and u16(b, 20) == 1
                   and u16(b, 22) == 2 and u32(b, 24) == 48000 and u16(b, 34) == 16 and b[36:40] == b'data'
                   and (u32(b, 40) >> 2) >= 256)
        if bmp_hit:
            length = u32(b, 2)
            if not reached:
                bmps.append((s, length, name_of(o, length)))
            reached = reached or len(bmps) >= TARGET
            gap = 0
            nxt = s + (1 if length == 0 else (length + 511) // 512)
            if (reached and wav) or nxt > SCAN_MAX:
                break
            s = nxt
        elif wav_hit:
            total = u32(b, 4) + 8
            words = u32(b, 40) >> 2
            words = WAV_MAX_WORDS if words > WAV_MAX_WORDS else words // 256 * 256
            if wav is None:
                wav = (s, words, total, name_of(o, total))
            gap = 0
            nxt = s + (total + 511) // 512
            if bmps or nxt > SCAN_MAX:
                break
            s = nxt
        else:
            if s >= SCAN_MAX or (reached and gap >= GAP - 1):
                break
            if reached:
                gap += 1
            s += 1

    print(f'扫描停在扇区 {s}（{s * 512 / 1e6:.1f}MB 处）')
    print('BMP：')
    for i, (sec, length, nm) in enumerate(bmps):
        print(f'  {i + 1}. 扇区 {sec:6d}  {length} 字节  {nm}')
    if wav:
        sec, words, total, nm = wav
        print(f'WAV：扇区 {sec}  {total} 字节  载入 {words} 个立体声样本 = {words / 48000:.2f} 秒  {nm}')
    else:
        print('WAV：没找到')

    ok = 1 <= len(bmps) <= TARGET and all(not n.startswith('(') for _, _, n in bmps) and wav and not wav[3].startswith('(')
    print('VERIFY PASS' if ok else 'VERIFY FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
