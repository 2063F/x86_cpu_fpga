#!/usr/bin/env python3
"""Convert a flat binary (e.g. `nasm -f bin`) to a Verilog $readmemh file.

Writes one byte per line, starting at address 0, for every byte of the input
(no address markers), so the file works with simulators and synthesis tools.

Usage: python3 tools/bin2hex.py program.bin program.hex
"""

import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    with open(sys.argv[2], "w") as f:
        for byte in data:
            f.write("%02x\n" % byte)


if __name__ == "__main__":
    main()
