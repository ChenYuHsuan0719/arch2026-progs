#!/usr/bin/env python3
"""Turn the C tables of the cube solver into an assembly file."""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
out = [
    "# Generated from rubik_tables.h by mytests/h2s.py. Do not edit.",
    "",
    "    .section .rodata",
]
kind = None
for line in open(src):
    m = re.match(r"\s*static const (uint8_t|uint16_t) (\w+)\[\d+\] = \{", line)
    if m:
        kind = ".byte" if m.group(1) == "uint8_t" else ".half"
        name = "rubik_tab_" + m.group(2)
        out += ["", "    .globl  " + name, "    .balign 2", name + ":"]
        continue
    if kind and line.strip().startswith("};"):
        kind = None
        continue
    if kind:
        nums = re.findall(r"\d+", line)
        if nums:
            out.append("    " + kind + "   " + ", ".join(nums))
open(dst, "w").write("\n".join(out) + "\n")
