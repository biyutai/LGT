"""Read the LGT-S1 USB-UART stream (115200 8N1, TX only).

The firmware never accepts serial commands and only emits one readable status
line per second:

    UPTIME=01:02:03 IMAGE=2/4 AUTO_MODE=ON TF_CARD=READY ...

This tool only prints/captures.  Use Ctrl+C to stop.

    python scripts/uart_status_monitor.py COM5
    python scripts/uart_status_monitor.py COM5 --save demo_capture.txt
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="USB1 serial port, for example COM5")
    parser.add_argument("--save", type=Path, help="save raw status lines")
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        parser.error("pyserial is required: python -m pip install pyserial")

    capture = args.save.open("w", encoding="ascii", newline="\n") if args.save else None
    try:
        with serial.Serial(args.port, 115200, timeout=1) as port:
            print("LGT-S1 serial monitor (read-only, Ctrl+C to stop)", flush=True)
            while True:
                raw = port.readline()
                if not raw:
                    continue
                line = raw.decode("ascii", errors="replace").strip()
                if not line:
                    continue
                if capture is not None:
                    capture.write(line + "\n")
                    capture.flush()
                if line.startswith("UPTIME="):
                    print(line, flush=True)
    except KeyboardInterrupt:
        pass
    except serial.SerialException as exc:
        print(f"serial port error: {exc}", file=sys.stderr)
        return 1
    finally:
        if capture is not None:
            capture.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
