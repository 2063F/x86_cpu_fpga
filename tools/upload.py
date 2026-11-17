#!/usr/bin/env python3
"""Load a program into RAM through the UART monitor and run it.

The FPGA must be running firmware/monitor.asm (the default ROM of soc_top).
The program is written with the monitor's `w` command, read back with `d`
to verify it, and started with `g`. After that everything the program prints
is shown until Ctrl-C.

Requirements: `pip install pyserial` (not needed for --script)

Usage:
    python3 tools/upload.py PORT program.bin              # load at 0100, verify, run
    python3 tools/upload.py PORT program.bin --addr 2000  # load address (hex)
    python3 tools/upload.py PORT program.bin --no-run     # load only
    python3 tools/upload.py --script out.txt program.bin  # only write the monitor
                                                          # commands to a file

PORT is the serial port of the board, e.g. COM5 (Windows) or /dev/ttyUSB1 (Linux).
"""

import argparse
import re
import sys
import time

BAUD = 115200
PROMPT = b"> "
BYTES_PER_LINE = 16
VERIFY_CHUNK = 0x100


def write_commands(data, addr):
    """Monitor commands that write `data` to memory starting at `addr`."""
    lines = []
    for off in range(0, len(data), BYTES_PER_LINE):
        chunk = data[off:off + BYTES_PER_LINE]
        lines.append("w %04X %s" % (addr + off, " ".join("%02X" % b for b in chunk)))
    return lines


def parse_dump(text):
    """Bytes from the output of the monitor's `d` command ("0100: 12 34 ...")."""
    out = bytearray()
    for line in text.splitlines():
        m = re.match(r"^[0-9A-F]{4}:((?: [0-9A-F]{2})+)\s*$", line.strip())
        if m:
            out += bytes(int(x, 16) for x in m.group(1).split())
    return bytes(out)


class Monitor:
    def __init__(self, ser, timeout=3.0):
        self.ser = ser
        self.timeout = timeout

    def read_until_prompt(self):
        """Read until the monitor prints its prompt. Returns the text before it."""
        buf = b""
        deadline = time.monotonic() + self.timeout
        while not buf.endswith(PROMPT):
            chunk = self.ser.read(max(1, self.ser.in_waiting))
            if chunk:
                buf += chunk
                deadline = time.monotonic() + self.timeout
            elif time.monotonic() > deadline:
                raise RuntimeError(
                    "no prompt from the monitor (received %r).\n"
                    "Check the serial port, and press the reset button on the board."
                    % buf[-60:])
        return buf[:-len(PROMPT)].decode("ascii", "replace")

    def command(self, line):
        """Send one command line; return what the monitor printed in response."""
        self.ser.write(line.encode("ascii") + b"\r")
        text = self.read_until_prompt()
        # The monitor echoes the command line first
        return text.split("\n", 1)[1] if "\n" in text else ""

    def sync(self):
        self.ser.reset_input_buffer()
        self.ser.write(b"\r")
        self.read_until_prompt()

    def load(self, data, addr):
        for line in write_commands(data, addr):
            if "?" in self.command(line):
                raise RuntimeError("the monitor rejected: %s" % line)

    def verify(self, data, addr):
        for off in range(0, len(data), VERIFY_CHUNK):
            want = data[off:off + VERIFY_CHUNK]
            got = parse_dump(self.command("d %04X %X" % (addr + off, len(want))))
            if got != want:
                for i, (a, b) in enumerate(zip(got, want)):
                    if a != b:
                        raise RuntimeError(
                            "verify failed at %04X: wrote %02X, read %02X"
                            % (addr + off + i, b, a))
                raise RuntimeError("verify failed at %04X: short read" % (addr + off))


def main():
    ap = argparse.ArgumentParser(
        description="Load a program through the UART monitor and run it.")
    ap.add_argument("port", nargs="?", help="serial port (e.g. COM5, /dev/ttyUSB1)")
    ap.add_argument("binary", help="flat binary file (nasm -f bin)")
    ap.add_argument("--addr", default="100", help="load address in hex (default 100)")
    ap.add_argument("--no-run", action="store_true", help="do not start the program")
    ap.add_argument("--no-verify", action="store_true", help="skip the read-back check")
    ap.add_argument("--script", metavar="FILE",
                    help="write the monitor commands to FILE instead of using a serial port")
    args = ap.parse_args()

    addr = int(args.addr, 16)
    with open(args.binary, "rb") as f:
        data = f.read()
    if not data:
        sys.exit("%s is empty" % args.binary)
    if addr + len(data) > 0x7E00:
        sys.exit("program does not fit below 7E00 (the monitor uses 7E00-7FFF)")

    if args.script:
        lines = write_commands(data, addr)
        if not args.no_run:
            lines.append("g %04X" % addr)
        with open(args.script, "w", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        print("wrote %d commands to %s" % (len(lines), args.script))
        return

    if not args.port:
        ap.error("PORT is required (or use --script)")

    try:
        import serial
    except ImportError:
        sys.exit("The 'pyserial' package is required:  pip install pyserial")

    with serial.Serial(args.port, BAUD, timeout=0.05) as ser:
        mon = Monitor(ser)
        try:
            mon.sync()
            print("loading %d bytes at %04X ..." % (len(data), addr))
            mon.load(data, addr)
            if not args.no_verify:
                mon.verify(data, addr)
                print("verify ok")
        except RuntimeError as e:
            sys.exit("error: %s" % e)

        if args.no_run:
            return

        print("running (Ctrl-C to quit)")
        ser.write(("g %04X\r" % addr).encode("ascii"))
        try:
            while True:
                chunk = ser.read(max(1, ser.in_waiting))
                if chunk:
                    sys.stdout.write(chunk.decode("ascii", "replace"))
                    sys.stdout.flush()
        except KeyboardInterrupt:
            print()


if __name__ == "__main__":
    main()
