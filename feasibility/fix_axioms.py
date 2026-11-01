#!/usr/bin/env python3
"""Applies the exact axiom sets LexLean reports, so a feasibility run doesn't take one CI round per definition."""
import json
import pathlib
import re
import sys

result = json.load(open(sys.argv[1]))
source_path = pathlib.Path(sys.argv[2])
source = source_path.read_text()
changed = 0
for diagnostic in result.get("diagnostics", []):
    match = re.search(r"`[\w.]*\.(\w+)` violates its exact axiom policy: observed \[(.*?)\]", diagnostic["message"])
    if not match:
        print("other diagnostic:", diagnostic["code"], diagnostic["message"][:600])
        continue
    name, observed = match.groups()
    axioms = [a.strip() for a in observed.split(",") if a.strip()]
    head = re.search(r"name: " + name + r",\n", source)
    end = source.index("\n}\n", head.end())
    block = source[head.end():end]
    block = re.sub(r"\n?\s*axioms: \[[^\]]*\],?", "", block)
    block = block.rstrip().rstrip(",")
    if axioms:
        block += ",\n  axioms: [" + ", ".join(sorted(axioms)) + "]"
    # A definition's fields are keyed, and fmt restores their canonical order.
    source = source[:head.end()] + block + source[end:]
    changed += 1
    print("axioms", name, axioms)
source_path.write_text(source)
sys.exit(0 if changed else 1)
