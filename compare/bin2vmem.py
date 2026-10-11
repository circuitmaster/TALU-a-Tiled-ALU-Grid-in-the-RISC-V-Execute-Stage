#!/usr/bin/env python3
"""bin -> Verilog vmem for the Vicuna simulator: 32-bit words, byte-swapped
(little-endian image, one word per line), starting at word address 0.
Equivalent to `srec_cat IN -binary -offset 0 -byte-swap 4 -o OUT -vmem`
for this use, without needing srecord installed.

  usage: bin2vmem.py IN.bin OUT.vmem
"""
import sys

data = open(sys.argv[1], "rb").read()
data += b"\x00" * (-len(data) % 4)
words = [data[i:i + 4][::-1].hex() for i in range(0, len(data), 4)]
with open(sys.argv[2], "w") as f:
    f.write("@0\n" + "\n".join(words) + "\n")
