#!/usr/bin/env python3
"""Convert a flat binary (e.g. `nasm -f bin`) to a Verilog $readmemh file.

One byte per line; runs of zero bytes are skipped using @address markers, so
the memory must be zero-initialized before the file is loaded.

Usage: python3 tools/bin2hex.py program.bin program.hex
"""

import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    with open(sys.argv[2], "w") as f:
        f.write("// %s (%d bytes)\n" % (sys.argv[1].replace("\\", "/").split("/")[-1], len(data)))
        prev = None
        for addr, byte in enumerate(data):
            if byte == 0:
                continue
            if prev is None or addr != prev + 1:
                f.write("@%04x\n" % addr)
            f.write("%02x\n" % byte)
            prev = addr


if __name__ == "__main__":
    main()
