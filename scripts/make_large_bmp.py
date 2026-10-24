"""Make an FPGA-compatible 24-bit bottom-up BMP for a scaling demo.

Usage: python scripts/make_large_bmp.py [--size WxH] INPUT OUTPUT

Default output is 1280x960 (the FPGA downsamples it). 本次数字标牌演示要求每张图源的
分辨率都不低于 640x480，所以也用它把小图重渲成 640x480（--size 640x480）。
"""

import argparse
from pathlib import Path

from PIL import Image, ImageOps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", default="1280x960",
                        help="output resolution, e.g. 1280x960 / 640x480")
    parser.add_argument("input_image", type=Path)
    parser.add_argument("output_bmp", type=Path)
    args = parser.parse_args()

    width, height = map(int, args.size.split("x"))
    with Image.open(args.input_image) as source:
        image = ImageOps.fit(source.convert("RGB"), (width, height), Image.Resampling.LANCZOS)
        args.output_bmp.parent.mkdir(parents=True, exist_ok=True)
        image.save(args.output_bmp, format="BMP")
    print(f"{args.output_bmp}: {width}x{height}, RGB24, uncompressed BMP")


if __name__ == "__main__":
    main()
