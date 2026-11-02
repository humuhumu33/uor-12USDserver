#!/usr/bin/env python3
"""Writes a LexLean project whose production root returns the server's real files as one archive.

Each file in the archive is its path, a newline, its length in decimal, a newline, and its bytes.
"""
import pathlib
import sys

# Sixteen appends per definition keep the nesting under the semantic-module JSON recursion limit.
APPENDS = 16
FILES = ["src/server.c", "build.sh", "install.sh", "start.sh", ".gitignore", "README.md"]

source = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])

archive = b""
for name in FILES:
    content = (source / name).read_bytes()
    archive += name.encode() + b"\n" + str(len(content)).encode() + b"\n" + content


def text(piece):
    """One literal: readable text, with the escapes LexLean strings accept."""
    escaped = piece.decode().replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    return f'(prim utf8_encode "{escaped}" : Bytes)'


# One literal per source line, so the module reads as the source does.
# A percent sign is forbidden anywhere in a LexLean file, so it is written as a byte.
parts = []
for line in archive.decode().splitlines(keepends=True):
    pieces = line.encode().split(b"%")
    for number, piece in enumerate(pieces):
        if number:
            parts.append("0x25")
        if piece:
            parts.append(text(piece))

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

(root / "src").mkdir(parents=True, exist_ok=True)
(root / "src" / "Emit.lex.tex").write_text(
    "\\begin{lexlean}{Emit}\n"
    "\\useglossary{lexlean.std.nat@1.2.0}\n"
    "\\title{Natural number addition}\n"
    "\\begin{semanticmodule}\n"
    + sections
    + "definition{\n  name: emitSource,\n  parameters: [seed : Bytes],\n  result: Bytes,\n"
    f"  body: {body},\n"
    "  executable: true,\n"
    "  production: {effects: [allocation], targets: [rust-std]}\n}\n"
    "\\end{semanticmodule}\n\\end{lexlean}\n",
    newline="\n",
)
(root / "lean-toolchain").write_text("leanprover/lean4:v4.32.1\n", newline="\n")
(root / "lakefile.toml").write_text('name = "uor_emit_host"\nversion = "0.1.0"\n', newline="\n")
(root / "lake-manifest.json").write_text(
    '{"version": "1.2.0",\n "packagesDir": ".lake/packages",\n "packages": [],\n "name": "uor_emit_host",\n'
    ' "lakeDir": ".lake",\n "fixedToolchain": false}\n',
    newline="\n",
)
config = (pathlib.Path(__file__).parent.parent / "feasibility" / "kernels" / "lexlean.toml").read_text()
config = (
    config.replace('name = "uor-kernels"', 'name = "uor-emit"')
    .replace('module_prefix = "UorKernels"', 'module_prefix = "UorEmit"')
    .replace("src/Kernels.lex.tex", "src/Emit.lex.tex")
    .replace("max_file_bytes = 4194304", "max_file_bytes = 67108864")
    .replace("max_child_output_bytes = 16777216", "max_child_output_bytes = 134217728")
)
(root / "lexlean.toml").write_text(config, newline="\n")
print("wrote", root, len(archive), "bytes in", len(parts), "literals")
