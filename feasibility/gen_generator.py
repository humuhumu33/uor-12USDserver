#!/usr/bin/env python3
"""Writes a LexLean project whose production root returns compilable C source of about the requested size."""
import pathlib
import sys

size = int(sys.argv[1])
chunk = int(sys.argv[2])
root = pathlib.Path(sys.argv[3])

line = b"/* padding standing in for emitted server source, which is about this dense. */\n"
text = b"int main(void) { return 42; }\n"
text += line * max(0, (size - len(text)) // len(line))
parts = [text[i : i + chunk] for i in range(0, len(text), chunk)]

# Sixteen appends per definition keep the nesting under the semantic-module JSON recursion limit.
sections = ""
body = "seed"
for start in range(0, len(parts), 16):
    number = start // 16
    inner = "seed"
    for part in parts[start : start + 16]:
        inner = f"(prim append {inner} 0x{part.hex()} : Bytes)"
    sections += (
        "definition{\n  name: section" + str(number) + ",\n  parameters: [seed : Bytes],\n  result: Bytes,\n"
        f"  body: {inner},\n  executable: true\n}}\n\n"
    )
    body = f"(section{number} {body})"

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
toml = pathlib.Path(__file__).parent / "kernels" / "lexlean.toml"
config = toml.read_text().replace('name = "uor-kernels"', 'name = "uor-emit"').replace('module_prefix = "UorKernels"', 'module_prefix = "UorEmit"').replace("src/Kernels.lex.tex", "src/Emit.lex.tex")
(root / "lexlean.toml").write_text(config, newline="\n")
print("wrote", root, len(text), "bytes in", len(parts), "literals")
