#!/usr/bin/env python3
"""Runs inside the locked SDK image. Can LexLean string literals carry C source as readable text?"""
import json
import os
import pathlib
import shutil
import subprocess

repo = pathlib.Path.cwd()
work = repo / "emit" / "work-probe"
shutil.rmtree(work, ignore_errors=True)


def project(name, module):
    d = work / name
    (d / "src").mkdir(parents=True)
    for f in ["lean-toolchain"]:
        shutil.copy(repo / "feasibility" / "kernels" / f, d / f)
    config = (repo / "feasibility" / "kernels" / "lexlean.toml").read_text()
    (d / "lexlean.toml").write_text(config.replace("src/Kernels.lex.tex", "src/Probe.lex.tex").replace("UorKernels", "UorProbe").replace("uor-kernels", "uor-probe"), newline="\n")
    (d / "lakefile.toml").write_text('name = "uor_emit_host"\nversion = "0.1.0"\n', newline="\n")
    (d / "lake-manifest.json").write_text('{"version": "1.2.0",\n "packagesDir": ".lake/packages",\n "packages": [],\n "name": "uor_emit_host",\n "lakeDir": ".lake",\n "fixedToolchain": false}\n', newline="\n")
    text = "\\begin{lexlean}{Probe}\n\\useglossary{lexlean.std.nat@1.2.0}\n\\title{Natural number addition}\n\\begin{semanticmodule}\n" + module + "\n\\end{semanticmodule}\n\\end{lexlean}\n"
    (d / "src" / "Probe.lex.tex").write_bytes(text.encode())
    return d


def definition(body, result="String", parameters="[seed : String]", extra=""):
    return "definition{\n  name: one,\n  parameters: " + parameters + ",\n  result: " + result + ",\n  body: " + body + ",\n  executable: true" + extra + "\n}"


def check(name, module):
    d = project(name, module)
    subprocess.run(["lexlean", "lock"], cwd=d, capture_output=True)
    r = subprocess.run(["lexlean", "--diagnostic-format", "json", "check"], cwd=d, capture_output=True, text=True)
    print("PROBE", name, "exit", r.returncode)
    try:
        for x in json.loads(r.stdout).get("diagnostics", [])[:2]:
            print("  ", x["code"], x["message"][:400], "|", "; ".join(x.get("help", []))[:300])
    except ValueError:
        print("  ", r.stdout[:400], r.stderr[:400])
    return r.returncode == 0


cases = {
    "string_append": definition('(prim append seed "abc" : String)'),
    "escape_quote": definition('(prim append seed "say \\"hi\\"" : String)'),
    "escape_backslash": definition('(prim append seed "a\\\\b" : String)'),
    "escape_newline": definition('(prim append seed "a\\nb" : String)'),
    "escape_tab": definition('(prim append seed "a\\tb" : String)'),
    "escape_cr": definition('(prim append seed "a\\rb" : String)'),
    "escape_hex": definition('(prim append seed "a\\x41b" : String)'),
    "raw_newline": definition('(prim append seed "a\nb" : String)'),
    "raw_percent": definition('(prim append seed "a%db" : String)'),
    "control_percent": definition('(prim append seed "a\\percent b" : String)'),
    "braces": definition('(prim append seed "int main(void) { return 42; }" : String)'),
    "c_symbols": definition('(prim append seed "#include <a.h> a & b ~c ^d $e _f [g] *p ?x :y ;z" : String)'),
    "comment_slashes": definition('(prim append seed "// note /* more */" : String)'),
    "single_quote": definition("(prim append seed \"c == '\\\\n'\" : String)"),
}
works = {}
for name, module in cases.items():
    works[name] = check(name, module)

# Is there a way from text to bytes?
for prim in ["utf8_encode", "encode_utf8", "string_to_bytes", "to_bytes", "from_string", "string_bytes", "utf8", "bytes_of_string"]:
    check("prim_" + prim, definition('(prim ' + prim + ' "abc" : Bytes)', result="Bytes", parameters="[seed : Bytes]"))

lexlean = shutil.which("lexlean")
print("LEXLEAN", lexlean)
print(subprocess.run(["lexlean", "--help"], capture_output=True, text=True).stdout[:1500])
blob = subprocess.run(f"strings -n 4 {lexlean} | grep -iE 'utf.?8|string_|_string|encode|decode|from_str|to_str' | sort -u | head -80", shell=True, capture_output=True, text=True)
print("STRINGS\n" + blob.stdout[:5000])

# Does a String root survive certification, and what does the generated crate return?
d = project("root", definition('(prim append seed "int main(void) { return 42; }" : String)', extra=",\n  production: {effects: [allocation], targets: [rust-std]}"))
targets = json.loads(subprocess.run(["lexlean", "production", "targets"], cwd=d, capture_output=True, text=True).stdout)
digest = {t["id"]: t["digest"] for t in targets["targets"]}["rust-std"]
(d / "request.json").write_text(json.dumps({"spec": "lexlean/production-request/1", "roots": [{"root": "UorProbe.Probe.one", "package": {"name": "kern_emit", "version": "0.1.0"}, "targets": [{"id": "rust-std", "digest": digest}]}]}))
subprocess.run(["lexlean", "lock"], cwd=d, capture_output=True)
r = subprocess.run(["lexlean", "--diagnostic-format", "json", "production", "build", "--request", "request.json"], cwd=d, capture_output=True, text=True)
print("ROOT exit", r.returncode)
try:
    for x in json.loads(r.stdout).get("diagnostics", [])[:4]:
        print("  ", x["code"], x["message"][:500])
except ValueError:
    print(r.stdout[:500], r.stderr[-500:])
for lib in d.rglob("kern_emit/src/lib.rs"):
    text = lib.read_text()
    print("LIB", len(text))
    for line in text.splitlines():
        if "pub fn" in line or "pub struct" in line or "pub type" in line:
            print("  ", line[:160])
    break
os.environ.get("HOME")
