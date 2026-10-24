"""生成第二首演示音乐：48kHz / 16 位 / 立体声 PCM，44 字节标准头

用途：TF 卡根目录里再放一首 WAV，KEY1 长按就能切歌（见 doc/系统架构与数据通路.md 第四节）。
长度 14.545 秒，正好落在"四图常驻"模式音频区上限之内
（RESIDENT_AUDIO_WORDS = 714752 个立体声样本 = 14.89 秒，超出会被截断）。

曲目：贝多芬《欢乐颂》主题（公有领域），132 BPM、4/4、8 小节，
      主旋律 + 低音 + 和声垫 + 柔和鼓点；首尾各 20ms 淡入淡出，循环接缝无爆音。

用法：
    python scripts/gen_demo_melody.py [输出.wav]
默认写到 assets/scale_demo/06_demo_melody.wav。
"""
import pathlib
import sys
import wave

import numpy as np

FS = 48000
BPM = 132.0
BEAT = 60.0 / BPM          # 0.4545 s
TOTAL_BEATS = 32           # 8 小节 × 4 拍
MAX_FRAMES = 714752        # 四图常驻模式的音频区上限（14.89 s）
FADE_MS = 20

FREQ = {'C3': 130.81, 'F3': 174.61, 'G3': 196.00,
        'C4': 261.63, 'D4': 293.66, 'E4': 329.63, 'F4': 349.23, 'G4': 392.00, 'A4': 440.00, 'B4': 493.88,
        'C5': 523.25, 'D5': 587.33, 'E5': 659.26, 'F5': 698.46, 'G5': 783.99}

# 《欢乐颂》主题（C 大调，四分音符为主），(音名, 拍数)
MELODY = [('E4', 1), ('E4', 1), ('F4', 1), ('G4', 1),
          ('G4', 1), ('F4', 1), ('E4', 1), ('D4', 1),
          ('C4', 1), ('C4', 1), ('D4', 1), ('E4', 1),
          ('E4', 1.5), ('D4', 0.5), ('D4', 2),
          ('E4', 1), ('E4', 1), ('F4', 1), ('G4', 1),
          ('G4', 1), ('F4', 1), ('E4', 1), ('D4', 1),
          ('C4', 1), ('C4', 1), ('D4', 1), ('E4', 1),
          ('D4', 1.5), ('C4', 0.5), ('C4', 2)]

# 每小节的和弦（低音根音 + 三和弦）
BARS = [('C3', ('C4', 'E4', 'G4')),
        ('G3', ('G4', 'B4', 'D4')),
        ('C3', ('C4', 'E4', 'G4')),
        ('G3', ('G4', 'B4', 'D4')),
        ('C3', ('C4', 'E4', 'G4')),
        ('G3', ('G4', 'B4', 'D4')),
        ('F3', ('F4', 'A4', 'C4')),
        ('C3', ('C4', 'E4', 'G4'))]


def tone(freq, dur, harmonics, tau, attack=0.005):
    """带包络的单音；harmonics = [(倍频, 幅度), ...]"""
    n = int(round(dur * FS))
    t = np.arange(n) / FS
    env = np.exp(-t / tau)
    a = int(round(min(attack, dur / 4) * FS))
    if a > 1:
        env[:a] *= np.linspace(0.0, 1.0, a)
    x = np.zeros(n)
    for mult, amp in harmonics:
        x += amp * np.sin(2 * np.pi * freq * mult * t)
    return x * env


def add(dst, at, sig, gain_l, gain_r):
    n = min(len(sig), len(dst) - at)
    if n <= 0:
        return
    dst[at:at + n, 0] += gain_l * sig[:n]
    dst[at:at + n, 1] += gain_r * sig[:n]


def build():
    total = int(round(TOTAL_BEATS * BEAT * FS))
    mix = np.zeros((total, 2))

    # 主旋律：偏左，带 2、3 次谐波，像拨弦音色
    pos = 0
    for name, beats in MELODY:
        dur = beats * BEAT
        add(mix, pos, tone(FREQ[name], dur, [(1, 1.0), (2, 0.45), (3, 0.18)], 0.42), 0.42, 0.32)
        pos += int(round(dur * FS))

    # 低音 + 和声垫：低音居中，垫音偏右，1 小节一个和弦
    bar = int(round(4 * BEAT * FS))
    for i, (root, triad) in enumerate(BARS):
        at = i * bar
        add(mix, at, tone(FREQ[root], 4 * BEAT, [(1, 1.0), (2, 0.22)], 1.1, 0.01), 0.30, 0.30)
        for note in triad:
            add(mix, at, tone(FREQ[note], 4 * BEAT, [(1, 1.0)], 2.2, 0.18), 0.055, 0.085)

    # 柔和鼓点：每小节第 1、3 拍（80Hz 正弦快速衰减 + 一点点点击声）
    for b in range(0, TOTAL_BEATS, 2):
        at = int(round(b * BEAT * FS))
        kick = tone(70.0, 0.18, [(1, 1.0)], 0.09, 0.001)
        click = np.exp(-np.arange(int(0.004 * FS)) / (0.0012 * FS)) * np.random.default_rng(1).standard_normal(int(0.004 * FS))
        add(mix, at, kick, 0.34, 0.34)
        add(mix, at, click, 0.05, 0.05)

    peak = float(np.max(np.abs(mix)))
    if peak > 0:
        mix *= 0.891 / peak            # -1 dBFS

    fade = min(int(FS * FADE_MS / 1000), total // 4)
    ramp = np.linspace(0.0, 1.0, fade)[:, None]
    mix[:fade] *= ramp
    mix[-fade:] *= ramp[::-1]

    # FPGA 载入的字数是 256 对齐的（bmp_read 里 wav_words = data_words[20:8] << 8），
    # 帧数不补齐的话末尾几十个样本会被裁掉；补齐到 256 的整数倍，尾部本来已经淡出，补 0 无声。
    if mix.shape[0] % 256:
        pad = 256 - mix.shape[0] % 256
        mix = np.vstack([mix, np.zeros((pad, 2))])
    return mix


def main():
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else \
        pathlib.Path(__file__).resolve().parent.parent / 'assets' / 'scale_demo' / '06_demo_melody.wav'
    mix = build()
    frames = mix.shape[0]
    if frames > MAX_FRAMES:
        raise SystemExit(f'太长：{frames} 帧 > 音频区上限 {MAX_FRAMES} 帧，会被 FPGA 截断')
    data = np.clip(np.round(mix * 32767.0), -32768, 32767).astype('<i2')
    out.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out), 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes(data.tobytes())
    print(f'写入 {out}')
    print(f'  16 位 / 立体声 / {FS} Hz，{frames} 帧 = {frames / FS:.3f} 秒，'
          f'峰值 {np.max(np.abs(data))} / 32767，文件 {out.stat().st_size} 字节')


if __name__ == '__main__':
    main()
