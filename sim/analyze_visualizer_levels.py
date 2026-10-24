"""Inspect the four current audio visualizer bands against a WAV fixture."""

import argparse
import collections
import struct
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav")
    args = parser.parse_args()
    with wave.open(args.wav, "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (2, 2, 48000):
            parser.error("expected 48 kHz, 16-bit stereo PCM")
        samples = struct.iter_unpack("<hh", source.readframes(source.getnframes()))
        slow = mid = fast = 0
        peaks = [0] * 4
        frames = []
        for n, (pcm, _) in enumerate(samples):
            values = (slow, mid - slow, fast - mid, pcm - fast)
            for band, value in enumerate(values):
                gain = (2, 2, 4, 8)[band]
                peaks[band] = max(peaks[band], min(255, (abs(value) >> 7) * gain))
            fast += (pcm - fast) >> 2
            mid += (pcm - mid) >> 4
            slow += (pcm - slow) >> 6
            if n % 800 == 799:
                frames.append(tuple(peaks))
                peaks = [0] * 4

    for band in range(4):
        levels = [frame[band] for frame in frames]
        lit = collections.Counter(sum(value >= t for t in (16, 48, 88, 152)) for value in levels)
        print(f"band {band}: min={min(levels)} median={sorted(levels)[len(levels)//2]} "
              f"max={max(levels)} LED levels={dict(sorted(lit.items()))}")
    for rise in (12, 20, 28, 36):
        previous = cooldown = flashes = 0
        for frame in frames:
            energy = frame[0] + frame[1]
            if cooldown:
                cooldown -= 1
            elif energy >= 48 and energy > previous + rise:
                flashes += 1
                cooldown = 8
            previous = energy
        print(f"low-frequency onset flashes at rise {rise}: {flashes} in {len(frames)} video frames")
    print("first frames:", frames[:12])


if __name__ == "__main__":
    main()
