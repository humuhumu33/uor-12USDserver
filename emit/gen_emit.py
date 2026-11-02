#!/usr/bin/env python3
"""Writes the LexLean project whose production root returns the server's files as one archive.

The proved core comes from core.lex; its tables are computed by the root. The rest of the server is carried as text.
Each file in the archive is its path, a newline, its bytes, and a zero byte.
"""
import json
import pathlib
import re
import sys

# Sixteen appends per definition keep the nesting under the semantic-module JSON recursion limit.
APPENDS = 16
FILES = ["src/server.c", "build.sh", "install.sh", "start.sh", ".gitignore", "README.md"]
HERE = pathlib.Path(__file__).parent

source = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])


def text(piece):
    """One literal: readable text, with the escapes LexLean strings accept."""
    escaped = piece.decode().replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    return f'(prim utf8_encode "{escaped}" : Bytes)'


def literals(data):
    # One literal per source line, so the module reads as the source does. Three things are written as bytes: a percent
    # sign and a zero byte, both forbidden anywhere in a LexLean file, and the slash of anything like a path, which
    # certification rejects when it sees an absolute path in Lean's output (LLV7006).
    parts = []
    for line in data.decode().splitlines(keepends=True):
        for piece in re.split(rb"(%|\x00|/(?=[A-Za-z0-9._~$-]))", line.encode()):
            if piece in (b"%", b"/", b"\x00"):
                parts.append("0x" + piece.hex())
            elif piece:
                parts.append(text(piece))
    return parts


def exhaust(variables, definitions):
    """Case analysis on every value of the listed finite variables, each case closed by unfolding the definitions."""
    if not variables:
        if not definitions:
            # Lean rejects a definition a simplification leaves unused, so a check that stops early is computed instead.
            return "reflexivity{}"
        return "simplify{definitions: [" + ", ".join(sorted(definitions)) + "]}"
    name, constructors = variables[0]
    branches = [
        # The notation reads a bare true or false as a boolean, and a constructor must be a name.
        "{proof: " + exhaust(variables[1:], definitions) + ", binders: [], constructor: " + (f'"{c}"' if c in ("true", "false") else c) + "}"
        for c in constructors
    ]
    return "induction{branches: [" + ", ".join(branches) + "], scrutinee: " + name + "}"


def expand_exhaust(match):
    groups = match.group(1).split(";")
    definitions = [d for d in groups[-1].split(",") if d]
    variables = []
    for group in groups[:-1]:
        if group:
            name, constructors = group.split(":")
            variables.append((name, constructors.split(",")))
    return exhaust(variables, definitions)


def escape_rows():
    rows = ""
    for row in range(16):
        cells = [f"(escapeCell ({row * 16 + cell} : UInt8))" for cell in range(16)]
        groups = [f"(cat4 {' '.join(cells[i : i + 4])})" for i in range(0, 16, 4)]
        rows += (
            "definition{\n  name: escapeRow" + str(row) + ",\n  parameters: [],\n  result: Bytes,\n"
            f'  body: (cat3 T"    " (cat4 {" ".join(groups)}) T"\\n"),\n  executable: true\n}}\n\n'
        )
    groups = []
    for start in range(0, 16, 4):
        groups.append("(cat4 " + " ".join(f"(escapeRow{start + i})" for i in range(4)) + ")")
    rows += (
        "definition{\n  name: escapeTable,\n  parameters: [],\n  result: Bytes,\n"
        f"  body: (cat4 {' '.join(groups)}),\n  executable: true\n}}\n"
    )
    return rows


core = (HERE / "core.lex").read_text()
core = core.replace("ESCAPE_ROWS\n", escape_rows())
core = re.sub(r"EXHAUST\(([^)]*)\)", expand_exhaust, core)
core = re.sub(r'T"((?:[^"\\]|\\.)*)"', lambda m: f'(prim utf8_encode "{m.group(1)}" : Bytes)', core)
axioms_path = HERE / "axioms.json"
axioms = json.loads(axioms_path.read_text()) if axioms_path.exists() else {}

archive = b""
for name in FILES:
    content = (source / name).read_bytes()
    archive += name.encode() + b"\n" + content + b"\0"
parts = literals(archive)

sections = ""
for start in range(0, len(parts), APPENDS):
    number = start // APPENDS
    inner = "seed"
    for part in parts[start : start + APPENDS]:
        inner = f"(prim append {inner}\n    {part} : Bytes)"
    sections += (
        "definition{\n  name: section" + str(number) + ",\n  parameters: [seed : Bytes],\n  result: Bytes,\n"
        f"  body: {inner},\n  executable: true\n}}\n\n"
    )

# The same limit applies to calls, so sections are grouped, sixteen to a chapter.
count = (len(parts) + APPENDS - 1) // APPENDS
body = "seed"
for start in range(0, count, APPENDS):
    number = start // APPENDS
    inner = "seed"
    for section in range(start, min(start + APPENDS, count)):
        inner = f"(section{section} {inner})"
    sections += (
        "definition{\n  name: chapter" + str(number) + ",\n  parameters: [seed : Bytes],\n  result: Bytes,\n"
        f"  body: {inner},\n  executable: true\n}}\n\n"
    )
    body = f"(chapter{number} {body})"

header_name = literals(b"src/core.h\n")
carried = body
for part in header_name:
    carried = f"(prim append {carried} {part} : Bytes)"
body = f"(prim append (prim append {carried} (coreHeader) : Bytes) 0x00 : Bytes)"

module = (
    "\\begin{lexlean}{Emit}\n"
    "\\useglossary{lexlean.std.bool@1.2.0}\n"
    "\\useglossary{lexlean.std.nat@1.2.0}\n"
    "\\title{Natural number addition}\n"
    "\\begin{semanticmodule}\n"
    + core
    + "\n"
    + sections
    + "definition{\n  name: emitSource,\n  parameters: [seed : Bytes],\n  result: Bytes,\n"
    f"  body: {body},\n"
    "  executable: true,\n"
    "  production: {effects: [allocation], targets: [rust-std]}\n}\n"
    "\\end{semanticmodule}\n\\end{lexlean}\n"
)
for name, observed in axioms.items():
    head = re.search(r"name: " + name + r",\n", module)
    if not head:
        continue
    end = module.index("\n}\n", head.end())
    block = module[head.end() : end].rstrip().rstrip(",")
    if observed:
        block += ",\n  axioms: [" + ", ".join(sorted(observed)) + "]"
    module = module[: head.end()] + block + module[end:]

(root / "src").mkdir(parents=True, exist_ok=True)
(root / "src" / "Emit.lex.tex").write_text(module, newline="\n")
(root / "lean-toolchain").write_text("leanprover/lean4:v4.32.1\n", newline="\n")
(root / "lakefile.toml").write_text('name = "uor_emit_host"\nversion = "0.1.0"\n', newline="\n")
(root / "lake-manifest.json").write_text(
    '{"version": "1.2.0",\n "packagesDir": ".lake/packages",\n "packages": [],\n "name": "uor_emit_host",\n'
    ' "lakeDir": ".lake",\n "fixedToolchain": false}\n',
    newline="\n",
)
config = (HERE.parent / "feasibility" / "kernels" / "lexlean.toml").read_text()
config = (
    config.replace('name = "uor-kernels"', 'name = "uor-emit"')
    .replace('module_prefix = "UorKernels"', 'module_prefix = "UorEmit"')
    .replace("src/Kernels.lex.tex", "src/Emit.lex.tex")
    .replace("max_file_bytes = 4194304", "max_file_bytes = 67108864")
    .replace("max_child_output_bytes = 16777216", "max_child_output_bytes = 134217728")
)
(root / "lexlean.toml").write_text(config, newline="\n")
print("wrote", root, len(archive), "carried bytes in", len(parts), "literals")
