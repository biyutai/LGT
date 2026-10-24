# -*- coding: utf-8 -*-
"""生成 V2 的两段 48 kHz / 16-bit / 立体声 WAV。

  01_campus_daily.wav     12 秒平静校园 BGM（可循环，带柔和低频节拍）
  02_emergency_alert.wav  中文 TTS 应急播报（从 emergency_voice_raw.wav 转换）
  backup/02_emergency_siren.wav  备用双音警笛

FPGA 端只接受 44 字节标准头、PCM、双声道、48 kHz、16 bit、data 从第 36 字节开始。
Python 的 wave 模块写出的正是这种格式。
"""

from __future__ import annotations

from pathlib import Path
import wave

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/campus_emergency"
BACKUP = OUT / "backup"
RAW_TTS = Path("C:/Users/lenovo/AppData/Local/Temp/emergency_voice_raw.wav")

SR = 48000


def write_wav(path: Path, stereo: np.ndarray) -> None:
    """stereo: float32/int16 array shape (n, 2), range -1..1 or int16."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = np.asarray(stereo)
    if data.dtype != np.int16:
        data = np.clip(data, -1.0, 1.0)
        data = (data * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def fade(x: np.ndarray, ms: float = 20.0) -> np.ndarray:
    n = max(1, int(SR * ms / 1000.0))
    env = np.ones(len(x), dtype=np.float32)
    env[:n] = np.linspace(0.0, 1.0, n, dtype=np.float32)
    env[-n:] = np.linspace(1.0, 0.0, n, dtype=np.float32)
    return x * env[:, None]


def normalize(x: np.ndarray, peak: float = 0.89) -> np.ndarray:
    m = float(np.max(np.abs(x)))
    return x if m <= 1e-9 else x * (peak / m)


def make_daily(path: Path) -> None:
    dur = 12.0
    n = int(SR * dur)
    t = np.arange(n, dtype=np.float32) / SR
    mix = np.zeros((n, 2), dtype=np.float32)

    # 四段和弦，每段 3 秒：Cmaj7 -> Am7 -> Fmaj7 -> G7
    chords = [
        (261.63, 329.63, 392.00, 493.88),
        (220.00, 261.63, 329.63, 392.00),
        (174.61, 220.00, 261.63, 329.63),
        (196.00, 246.94, 293.66, 349.23),
    ]
    roots = [130.81, 110.00, 87.31, 98.00]
    seg = dur / len(chords)
    for i, (chord, root) in enumerate(zip(chords, roots)):
        start = int(i * seg * SR)
        end = int((i + 1) * seg * SR)
        tt = t[start:end] - t[start]
        env = np.minimum(tt / 0.35, 1.0) * np.minimum((seg - tt) / 0.55, 1.0)
        env = np.clip(env, 0.0, 1.0).astype(np.float32)
        pad = np.zeros_like(tt)
        for f in chord:
            pad += 0.16 * np.sin(2 * np.pi * f * tt)
            pad += 0.05 * np.sin(2 * np.pi * f * 1.003 * tt + 0.7)
        pad *= env
        bass = 0.22 * np.sin(2 * np.pi * root * tt) * env
        # 左/右轻微失谐，形成宽度
        mix[start:end, 0] += pad * 0.95 + bass
        mix[start:end, 1] += pad * 1.00 + bass

    # 90 BPM：去掉强低频鼓点，只保留很轻的低频心跳，给频段柱一点低端内容
    beat = 60.0 / 90.0
    for t0 in np.arange(0.0, dur, beat):
        start = int(t0 * SR)
        length = int(0.12 * SR)
        end = min(n, start + length)
        tt = np.arange(end - start, dtype=np.float32) / SR
        env = np.exp(-tt / 0.05).astype(np.float32)
        pulse = 0.055 * np.sin(2 * np.pi * 55.0 * tt) * env
        mix[start:end, 0] += pulse
        mix[start:end, 1] += pulse

    # 柔和校园钟声：每 4 秒一次（1s / 5s / 9s），给主题一点“校园”标识
    for bell_t in (1.0, 5.0, 9.0):
        start = int(bell_t * SR)
        length = int(1.2 * SR)
        end = min(n, start + length)
        tt = np.arange(end - start, dtype=np.float32) / SR
        env = (np.minimum(tt / 0.006, 1.0) * np.exp(-tt / 0.42)).astype(np.float32)
        bell = (0.075 * np.sin(2 * np.pi * 1046.50 * tt) +
                0.026 * np.sin(2 * np.pi * 2093.00 * tt) +
                0.012 * np.sin(2 * np.pi * 3136.00 * tt)) * env
        mix[start:end, 0] += bell * 0.9
        mix[start:end, 1] += bell

    # 轻巧的琶音（每拍一个和弦音），给高频段一点内容
    arp_notes = [523.25, 659.25, 783.99, 987.77, 880.00]
    for k, t0 in enumerate(np.arange(0.0, dur, beat)):
        start = int(t0 * SR)
        length = int(0.35 * SR)
        end = min(n, start + length)
        tt = np.arange(end - start, dtype=np.float32) / SR
        env = np.exp(-tt / 0.10).astype(np.float32)
        f = arp_notes[k % len(arp_notes)]
        note = 0.07 * np.sin(2 * np.pi * f * tt) * env
        mix[start:end, 0] += note * 0.9
        mix[start:end, 1] += note

    mix = normalize(mix, 0.89)
    mix = fade(mix, 25.0)
    write_wav(path, mix)
    print(f"{path.name}: {n} samples = {n / SR:.2f}s")


def make_exhibition(path: Path) -> None:
    """12 秒展陈 BGM：112 BPM、拨弦琶音 + 轻打击 + 暖 pad，和日常 BGM 明显不同。"""
    dur = 12.0
    n = int(SR * dur)
    t = np.arange(n, dtype=np.float32) / SR
    mix = np.zeros((n, 2), dtype=np.float32)

    # Fmaj7 -> G6 -> Em7 -> Am7
    chords = [
        (174.61, 220.00, 261.63, 329.63),
        (196.00, 246.94, 293.66, 329.63),
        (164.81, 196.00, 246.94, 293.66),
        (220.00, 261.63, 329.63, 392.00),
    ]
    roots = [87.31, 98.00, 82.41, 110.00]
    seg = dur / len(chords)
    for i, (chord, root) in enumerate(zip(chords, roots)):
        start = int(i * seg * SR)
        end = int((i + 1) * seg * SR)
        tt = t[start:end] - t[start]
        env = np.minimum(tt / 0.25, 1.0) * np.minimum((seg - tt) / 0.45, 1.0)
        env = np.clip(env, 0.0, 1.0).astype(np.float32)
        pad = np.zeros_like(tt)
        for f in chord:
            pad += 0.055 * np.sin(2 * np.pi * f * tt)
        mix[start:end, 0] += pad * env
        mix[start:end, 1] += pad * env
        bass = 0.16 * np.sin(2 * np.pi * root * tt) * env
        mix[start:end, 0] += bass
        mix[start:end, 1] += bass

    beat = 60.0 / 112.0
    arp_notes = [349.23, 440.00, 523.25, 659.25, 587.33, 493.88]
    for k, t0 in enumerate(np.arange(0.0, dur, beat)):
        start = int(t0 * SR)
        length = int(0.32 * SR)
        end = min(n, start + length)
        tt = np.arange(end - start, dtype=np.float32) / SR
        env = np.exp(-tt / 0.16).astype(np.float32)
        f = arp_notes[k % len(arp_notes)]
        note = (0.11 * np.sin(2 * np.pi * f * tt) +
                0.025 * np.sin(2 * np.pi * 2 * f * tt)) * env
        pan = 0.35 if k % 2 == 0 else 0.65
        mix[start:end, 0] += note * (1.0 - pan) * 1.4
        mix[start:end, 1] += note * pan * 1.4

    # 轻巧的高频节拍，给频段柱一点高频内容
    for t0 in np.arange(0.0, dur, beat):
        start = int(t0 * SR)
        length = int(0.04 * SR)
        end = min(n, start + length)
        tt = np.arange(end - start, dtype=np.float32) / SR
        env = np.exp(-tt / 0.012).astype(np.float32)
        tick = 0.035 * np.sin(2 * np.pi * 6200 * tt) * env
        mix[start:end, 0] += tick
        mix[start:end, 1] += tick

    # 每两拍一次柔和低频脉冲
    for t0 in np.arange(0.0, dur, beat * 2):
        start = int(t0 * SR)
        length = int(0.10 * SR)
        end = min(n, start + length)
        tt = np.arange(end - start, dtype=np.float32) / SR
        env = np.exp(-tt / 0.04).astype(np.float32)
        pulse = 0.06 * np.sin(2 * np.pi * 60 * tt) * env
        mix[start:end, 0] += pulse
        mix[start:end, 1] += pulse

    mix = normalize(mix, 0.89)
    mix = fade(mix, 25.0)
    write_wav(path, mix)
    print(f"{path.name}: {n} samples = {n / SR:.2f}s")


def convert_tts(raw: Path, path: Path) -> None:
    if not raw.exists():
        raise SystemExit(f"missing TTS raw file: {raw}")
    with wave.open(str(raw), "rb") as r:
        ch, width, rate, frames = (r.getnchannels(), r.getsampwidth(),
                                   r.getframerate(), r.getnframes())
        data = r.readframes(frames)
    if width != 2:
        raise SystemExit(f"TTS raw must be 16-bit, got {width*8}-bit")
    x = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
    if ch == 2:
        x = x.reshape(-1, 2)
    elif ch == 1:
        x = np.repeat(x[:, None], 2, axis=1)
    else:
        raise SystemExit(f"unsupported TTS channels: {ch}")

    # 重采样到 48 kHz（线性插值；语音足够）
    if rate != SR:
        n_out = int(round(len(x) * SR / rate))
        old_t = np.arange(len(x), dtype=np.float64) / rate
        new_t = np.arange(n_out, dtype=np.float64) / SR
        x = np.stack([np.interp(new_t, old_t, x[:, c]) for c in range(2)], axis=1)
        x = x.astype(np.float32)

    # 去掉首尾静音，再留 80 ms / 250 ms 余量
    mono = np.max(np.abs(x), axis=1)
    idx = np.flatnonzero(mono > 0.01)
    if len(idx):
        a = max(0, idx[0] - int(0.08 * SR))
        b = min(len(x), idx[-1] + int(0.25 * SR))
        x = x[a:b]

    x = normalize(x, 0.92)
    x = fade(x, 12.0)
    write_wav(path, x)
    print(f"{path.name}: {len(x)} samples = {len(x) / SR:.2f}s")


def make_siren(path: Path) -> None:
    dur = 4.0
    n = int(SR * dur)
    t = np.arange(n, dtype=np.float32) / SR
    # 800 Hz / 1000 Hz 交替，每 0.5 秒；带 10 ms 交叠
    sig = np.zeros(n, dtype=np.float32)
    for k, start in enumerate(np.arange(0.0, dur, 0.5)):
        a = int(start * SR)
        b = min(n, int((start + 0.5) * SR))
        tt = np.arange(b - a, dtype=np.float32) / SR
        f = 800.0 if k % 2 == 0 else 1000.0
        env = np.minimum(tt / 0.01, 1.0) * np.minimum((0.5 - tt) / 0.03, 1.0)
        sig[a:b] += (0.42 * np.sin(2 * np.pi * f * tt) * env).astype(np.float32)
    stereo = np.stack([sig, sig], axis=1)
    stereo = fade(normalize(stereo, 0.85), 15.0)
    write_wav(path, stereo)
    print(f"{path.name}: {n} samples = {n / SR:.2f}s")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    BACKUP.mkdir(parents=True, exist_ok=True)
    make_daily(OUT / "01_campus_daily.wav")
    make_exhibition(OUT / "02_exhibition_bgm.wav")
    convert_tts(RAW_TTS, OUT / "03_emergency_alert.wav")
    make_siren(BACKUP / "03_emergency_siren.wav")


if __name__ == "__main__":
    main()
