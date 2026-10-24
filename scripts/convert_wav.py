"""把任意 WAV 转成 FPGA 能播放的格式：48kHz、16 位、立体声、标准 44 字节头，最长 27.69 秒

用法：
    python scripts/convert_wav.py 输入.wav [输出.wav] [--start 秒] [--duration 秒] [--no-normalize]
    python scripts/convert_wav.py --demo 输出.wav          # 生成一段 12 秒的测试和弦

FPGA 端（bmp_read.v）只认这种格式：
    RIFF / WAVE / 16 字节 "fmt "（PCM、2 声道、48000Hz、16 位）/ "data"，样本从第 44 字节开始
做的处理：
    任意采样率 → 48kHz（多相滤波重采样）；单声道复制成双声道，多声道取前两个
    截到 SDRAM 音频区放得下的长度（1329152 个立体声样本 = 27.69 秒），再取整到 256 个样本
    归一化到 -1dBFS；首尾各 20ms 淡入淡出，循环播放时接缝处不会"咔"一声
需要：numpy、scipy（输入 WAV 可以是 8/16/24/32 位整数或浮点）
"""
import argparse
import math
import pathlib
import struct
import sys
import wave

import numpy as np

FS = 48000
MAX_SAMPLES = 1329152        # = 2^21 - 2 × 307200 - 4 × 38400 字
FADE_MS = 20


def to_float(x):
    if x.dtype == np.uint8:
        return (x.astype(np.float64) - 128.0) / 128.0
    if np.issubdtype(x.dtype, np.integer):
        return x.astype(np.float64) / float(np.iinfo(x.dtype).max + 1)
    return x.astype(np.float64)


def demo():
    """C - Am - F - G 四个和弦各 3 秒，带一点包络，方便听出循环和左右声道"""
    chords = [(261.63, 329.63, 392.00), (220.00, 261.63, 329.63), (174.61, 220.00, 261.63), (196.00, 246.94, 293.66)]
    seg = 3 * FS
    t = np.arange(seg) / FS
    # 起音 50ms 渐入 + 指数衰减 + 最后 40ms 收到 0：每个和弦首尾都是 0，换和弦时不会突变出咔哒声
    release = int(0.04 * FS)
    tail = np.ones(seg)
    tail[-release:] = 0.5 * (1 + np.cos(np.linspace(0, np.pi, release)))
    env = np.minimum(1.0, t / 0.05) * np.exp(-t * 0.6) * tail
    left, right = [], []
    for root, third, fifth in chords:
        left.append(env * (np.sin(2 * np.pi * root * t) + 0.5 * np.sin(2 * np.pi * fifth * t)))
        right.append(env * (np.sin(2 * np.pi * third * t) + 0.5 * np.sin(2 * np.pi * root * 2 * t)))
    return np.stack([np.concatenate(left), np.concatenate(right)], axis=1)


def demo_beat():
    """The 12-second chord demo with soft bass drum beats at 120 BPM."""
    audio = demo() * 0.72
    kick_len = int(0.18 * FS)
    kt = np.arange(kick_len) / FS
    attack = np.minimum(1.0, kt / 0.008)
    kick = attack * np.sin(2 * np.pi * (62 * kt + 42 * kt * np.exp(-kt * 28))) * np.exp(-kt * 24)
    for beat in range(24):
        offset = beat * (FS // 2)
        audio[offset:offset + kick_len, :] += 0.40 * kick[:, None]
    return audio


def check_header(path):
    b = pathlib.Path(path).read_bytes()[:44]
    riff, _, wave, fmt, fmt_len, af, ch, rate, _, _, bits, data = struct.unpack('<4sI4s4sIHHIIHH4s', b[:40])
    ok = (riff, wave, fmt, data) == (b'RIFF', b'WAVE', b'fmt ', b'data') and (fmt_len, af, ch, rate, bits) == (16, 1, 2, FS, 16)
    if not ok:
        sys.exit(f'[错误] 写出的文件头不是 FPGA 要求的 44 字节标准头：{path}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input', nargs='?')
    ap.add_argument('output', nargs='?')
    ap.add_argument('--start', type=float, default=0.0, help='从第几秒开始截取')
    ap.add_argument('--duration', type=float, default=None, help='截取多少秒（默认能放多长放多长）')
    ap.add_argument('--no-normalize', action='store_true', help='不做音量归一化')
    ap.add_argument('--demo', metavar='OUT', help='不读输入，生成测试和弦写到 OUT')
    ap.add_argument('--demo-beat', metavar='OUT', help='生成带柔和 120 BPM 低频鼓点的 12 秒演示 WAV')
    a = ap.parse_args()

    if a.demo_beat:
        x, rate, out = demo_beat(), FS, a.demo_beat
    elif a.demo:
        x, rate, out = demo(), FS, a.demo
    else:
        if not a.input:
            ap.error('需要输入文件，或者用 --demo')
        from scipy.io import wavfile
        rate, raw = wavfile.read(a.input)
        x = to_float(raw)
        out = a.output or str(pathlib.Path(a.input).with_name(pathlib.Path(a.input).stem + '_fpga.wav'))

    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    elif x.shape[1] == 1:
        x = np.repeat(x, 2, axis=1)
    else:
        x = x[:, :2]

    if rate != FS:
        from scipy.signal import resample_poly
        g = math.gcd(FS, rate)
        x = resample_poly(x, FS // g, rate // g, axis=0)

    start = int(a.start * FS)
    x = x[start:]
    n = len(x) if a.duration is None else min(len(x), int(a.duration * FS))
    n = min(n, MAX_SAMPLES) // 256 * 256
    if n == 0:
        sys.exit('[错误] 截取后不到 256 个样本')
    x = x[:n]

    if not a.no_normalize:
        peak = np.max(np.abs(x))
        if peak > 0:
            x = x * (10 ** (-1 / 20) / peak)

    fade = min(int(FS * FADE_MS / 1000), n // 4)
    ramp = np.linspace(0.0, 1.0, fade)[:, None]
    x[:fade] *= ramp
    x[-fade:] *= ramp[::-1]

    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype('<i2')
    with wave.open(str(out), 'wb') as target:
        target.setnchannels(2)
        target.setsampwidth(2)
        target.setframerate(FS)
        target.writeframes(pcm.tobytes())
    check_header(out)
    size = pathlib.Path(out).stat().st_size
    print(f'[成功] {out}')
    print(f'       48000Hz 16 位 立体声，{n} 个样本 = {n / FS:.2f} 秒，{size / 1e6:.2f}MB')
    print(f'       把它拷到 TF 卡根目录（BMP 之后拷），FPGA 开机后自动载入并循环播放')


if __name__ == '__main__':
    main()
