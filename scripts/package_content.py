"""Validate and package one LGT-S1 TF-card content set.

The output directory is ready to copy to a FAT32 card root.  A MANIFEST.TXT
records the product/model/firmware, file hashes, image order and the checks
that were run, so a deployment can be reproduced later.

Examples
--------
    python scripts/package_content.py assets/scale_demo --out build/card_demo
    python scripts/package_content.py content/site_a --out build/site_a --check-only

No external dependency is required.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import struct
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from check_playlist_font import font_chars


ROOT = Path(__file__).resolve().parents[1]
GEN = ROOT / "scripts/gen_osd_chinese_font.py"
SUPPORTED_BMP = {(640, 480), (320, 240), (320, 180), (1280, 960), (1024, 768)}
MAX_WAV_SAMPLES = 1329152
RESIDENT_WAV_SAMPLES = 714752
TRANSITIONS = {"淡入", "左揭示", "右揭示", "菱形溶解", "0", "1", "2", "3"}


@dataclass
class Item:
    path: Path
    kind: str
    detail: str


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_bmp(path: Path) -> tuple[bool, str]:
    data = path.read_bytes()
    if len(data) < 54 or data[:2] != b"BM":
        return False, "not a BMP"
    offset = struct.unpack_from("<I", data, 10)[0]
    dib = struct.unpack_from("<I", data, 14)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    planes, bpp = struct.unpack_from("<HH", data, 26)
    compression = struct.unpack_from("<I", data, 30)[0]
    if dib < 40 or planes != 1 or bpp != 24 or compression != 0:
        return False, "need 24-bit uncompressed BMP"
    if height <= 0:
        return False, "need bottom-up (positive height) BMP"
    if width <= 0 or (width, height) not in SUPPORTED_BMP:
        return False, f"unsupported size {width}x{height}"
    stride = ((width * 3 + 3) // 4) * 4
    if len(data) < offset + stride * height:
        return False, "truncated pixel data"
    return True, f"{width}x{height}, {len(data)} bytes"


def bmp_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as source:
        header = source.read(26)
    return struct.unpack_from("<ii", header, 18)


def check_wav(path: Path) -> tuple[bool, str]:
    data = path.read_bytes()
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return False, "not a RIFF/WAVE file"
    if data[12:16] != b"fmt ":
        return False, "missing fmt chunk at byte 12"
    fmt_size = struct.unpack_from("<I", data, 16)[0]
    audio_format, channels = struct.unpack_from("<HH", data, 20)
    sample_rate = struct.unpack_from("<I", data, 24)[0]
    byte_rate, block_align, bits = struct.unpack_from("<IHH", data, 28)
    if (fmt_size, audio_format, channels, sample_rate, byte_rate,
            block_align, bits) != (16, 1, 2, 48000, 192000, 4, 16):
        return False, "need PCM 48kHz / 16-bit / stereo"
    if data[36:40] != b"data":
        return False, "need a 44-byte header with data at byte 36"
    data_bytes = struct.unpack_from("<I", data, 40)[0]
    samples = data_bytes // 4
    if samples < 256:
        return False, "fewer than 256 stereo samples"
    if samples > MAX_WAV_SAMPLES:
        return False, f"{samples} samples exceeds firmware limit {MAX_WAV_SAMPLES}"
    warning = ""
    if samples > RESIDENT_WAV_SAMPLES:
        warning = (f" (>{RESIDENT_WAV_SAMPLES}; four-resident mode will use "
                   "the dual-buffer fallback)")
    return True, f"{samples} samples = {samples / 48000:.2f}s{warning}"


def check_playlist(path: Path, have: set[str]) -> tuple[bool, list[str]]:
    warnings: list[str] = []
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    entries = 0
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entries += 1
        if entries > 16:
            return False, [f"line {number}: more than 16 playlist entries"]
        fields = line.split(",", 3)
        if len(fields) < 2:
            return False, [f"line {number}: need at least index,seconds"]
        index = fields[0].strip()
        seconds = fields[1].strip()
        transition = fields[2].strip() if len(fields) >= 3 else "淡入"
        subtitle = fields[3] if len(fields) >= 4 else ""
        if not index.isdigit() or not 1 <= int(index) <= 4:
            return False, [f"line {number}: index must be 1..4 (four resident images)"]
        if seconds and (not seconds.isdigit() or int(seconds) > 99):
            return False, [f"line {number}: seconds must be empty or 0..99"]
        if transition and transition not in TRANSITIONS:
            warnings.append(f"line {number}: unknown transition {transition!r}, "
                            "firmware will fall back to 淡入")
        for language in subtitle.split("|"):
            for char in language:
                if char in " \t" or char in have:
                    continue
                warnings.append(f"line {number}: U+{ord(char):04X} {char!r} "
                                "has no 16x16 glyph")
    if entries == 0:
        return False, ["playlist has no entries"]
    return True, warnings


def collect(source: Path) -> tuple[list[Item], list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    items: list[Item] = []
    bmps = sorted(p for p in source.iterdir() if p.is_file() and p.suffix.lower() == ".bmp")
    wavs = sorted(p for p in source.iterdir() if p.is_file() and p.suffix.lower() == ".wav")
    if not bmps:
        errors.append("no BMP in source directory")
    if len(bmps) > 4:
        warnings.append(f"{len(bmps)} BMPs found; firmware only loads the first 4")
    if len(wavs) > 4:
        warnings.append(f"{len(wavs)} WAVs found; firmware indexes only the first 4")
    bmp_items = []
    for bmp in bmps[:4]:
        ok, detail = check_bmp(bmp)
        if ok:
            bmp_items.append(Item(bmp, "BMP", detail))
        else:
            errors.append(f"{bmp.name}: {detail}")
    bmp_items.sort(key=lambda item: (bmp_dimensions(item.path) != (640, 480),
                                      item.path.name))
    items.extend(bmp_items)
    for wav in wavs[:4]:
        ok, detail = check_wav(wav)
        if ok:
            items.append(Item(wav, "WAV", detail))
        else:
            errors.append(f"{wav.name}: {detail}")
    have = font_chars(GEN)
    playlist = source / "PLAYLIST.TXT"
    if playlist.exists():
        ok, messages = check_playlist(playlist, have)
        if ok:
            items.append(Item(playlist, "PLAYLIST", f"{len(messages)} warning(s)"))
            warnings.extend(messages)
        else:
            errors.extend(messages)
    else:
        warnings.append("no PLAYLIST.TXT; firmware will use directory order + audio beat")
    if (source / "TEXT.TXT").exists():
        warnings.append("TEXT.TXT is not used by the single-card firmware")
    return items, errors, warnings


def write_manifest(out: Path, items: list[Item], warnings: list[str]) -> None:
    lines = [
        "LGT-S1 CONTENT MANIFEST",
        "product=LGT 音画同频数字标牌",
        "model=LGT-S1",
        "firmware_compat=1.0.0",
        f"generated={datetime.now().astimezone().isoformat(timespec='seconds')}",
        "",
        "files:",
    ]
    for item in items:
        lines.append(f"  {item.kind:8s} {item.path.name}")
        lines.append(f"           sha256={sha256(item.path)}")
        lines.append(f"           detail={item.detail}")
    if warnings:
        lines += ["", "warnings:"]
        lines += [f"  - {warning}" for warning in warnings]
    lines += [
        "",
        "notes:",
        "  - Copy the files to the FAT32 card root in the listed order.",
        "  - BMP scan order follows the card directory order; the first 640x480 image starts fastest.",
        "  - The firmware ignores MANIFEST.TXT.",
        "  - Proof-of-play times are uptime-relative, not wall-clock.",
        "",
    ]
    (out / "MANIFEST.TXT").write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="directory with BMP/WAV/PLAYLIST/TEXT")
    parser.add_argument("--out", type=Path, help="output directory (omit for check-only)")
    parser.add_argument("--check-only", action="store_true", help="validate without copying")
    args = parser.parse_args(argv)

    if not args.source.is_dir():
        parser.error(f"not a directory: {args.source}")
    items, errors, warnings = collect(args.source)
    print(f"source: {args.source}")
    for item in items:
        print(f"  OK   {item.kind:8s} {item.path.name}: {item.detail}")
    for warning in warnings:
        print(f"  WARN {warning}")
    for error in errors:
        print(f"  FAIL {error}", file=sys.stderr)
    if errors:
        print(f"FAILED: {len(errors)} error(s)", file=sys.stderr)
        return 1

    if args.check_only or args.out is None:
        print("CHECK PASS (no output directory requested)")
        return 0
    args.out.mkdir(parents=True, exist_ok=True)
    for item in items:
        shutil.copy2(item.path, args.out / item.path.name)
    write_manifest(args.out, items, warnings)
    print(f"PACK PASS: {args.out} ({len(items)} content files + MANIFEST.TXT)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
