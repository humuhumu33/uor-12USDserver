#!/usr/bin/env python3
"""Writes kernels/src/Kernels.lex.tex. The word constants are easier to check here than as decimals."""
import pathlib
import struct


def le(text):
    return struct.unpack("<Q", text.encode().ljust(8, b"\0"))[0]


def hx(text):
    return "0x" + text.encode().hex()


def u(number):
    return f"({number} : UInt64)"


M = u(0x7F7F7F7F7F7F7F7F)
ALL = u(0xFFFFFFFFFFFFFFFF)
LOW32 = u(0xFFFFFFFF)
EXEC = "axioms: [Quot.sound, propext],\n  executable: true"


def word_is(name, text):
    return f"(prim equal {name} {u(le(text))} : Bool)"


def masked_is(name, mask, text):
    return f"(prim equal (prim bit_and {name} {u(mask)} : UInt64) {u(le(text))} : Bool)"


def enum(name, constructors):
    fields = ", ".join("{name: " + c + ", fields: []}" for c in constructors)
    return (
        "inductive{\n  name: " + name + ",\n  type_parameters: [],\n  parameters: [],\n"
        "  constructors: [" + fields + "]\n}\n"
    )


EVENTS = ["request", "batchEnd", "commitOk", "commitFail"]


def table(name, result, prefix, rows):
    arms = []
    for phase, targets in rows:
        inner = "\n".join(
            f"      | Event.{event} => (ctor {prefix}.{target})" for event, target in zip(EVENTS, targets)
        )
        arms.append(f"    | Phase.{phase} => (match event\n{inner})")
    body = "(match phase\n" + "\n".join(arms) + ")"
    return (
        "definition{\n  name: " + name + ",\n  parameters: [phase : Phase, event : Event],\n"
        "  result: " + result + ",\n  body: " + body + ",\n  executable: true\n}\n"
    )


def event_cases(phase):
    arms = ", ".join(
        "{proof: simplify{definitions: [actionOf]}, binders: [], constructor: " + e + "}" for e in EVENTS
    )
    return (
        "{proof: induction{branches: [" + arms + "], scrutinee: event}, binders: [], constructor: " + phase + "}"
    )


ROUTE = (
    f"(if ({word_is('w0', 'GET /fee')} && {word_is('w1', 'd HTTP/1')}) then (1 : UInt64) else "
    f"(if ({word_is('w0', 'GET /hea')} && {word_is('w1', 'lth HTTP')}) then (2 : UInt64) else "
    f"(if ({word_is('w0', 'GET /pos')} && {masked_is('w1', 0xFFFFFF, 'ts/')}) then (3 : UInt64) else "
    f"(if ({word_is('w0', 'POST /po')} && {word_is('w1', 'sts HTTP')}) then (4 : UInt64) else "
    f"(if ({word_is('w0', 'POST /po')} && {masked_is('w1', 0xFFFFFFFF, 'sts/')}) then (5 : UInt64) else "
    "(0 : UInt64))))))"
)

ROUTE_BYTES = (
    f"(if (startsWith raw {hx('GET /feed HTTP/1')} 16) then 1 else "
    f"(if (startsWith raw {hx('GET /health HTTP')} 16) then 2 else "
    f"(if (startsWith raw {hx('GET /posts/')} 11) then 3 else "
    f"(if (startsWith raw {hx('POST /posts HTTP')} 16) then 4 else "
    f"(if (startsWith raw {hx('POST /posts/')} 12) then 5 else 0)))))"
)


def rot(x, n):
    return f"(rotr32 {x} ({n} : UInt32) ({32 - n} : UInt32))"


def xor3(p, q, r):
    return f"(prim bit_xor (prim bit_xor {p} {q} : UInt64) {r} : UInt64)"


SHA_ROUND = (
    f"(let s1 : UInt64 := {xor3(rot('e', 6), rot('e', 11), rot('e', 25))}; "
    "(let ch : UInt64 := (prim bit_xor (prim bit_and e f : UInt64) (prim bit_and (prim bit_not e : UInt64) g : UInt64) : UInt64); "
    f"(let t1 : UInt64 := (add32 (add32 (add32 h s1) (prim bit_and ch {LOW32} : UInt64)) kw); "
    f"(let s0 : UInt64 := {xor3(rot('a', 2), rot('a', 13), rot('a', 22))}; "
    f"(let mj : UInt64 := {xor3('(prim bit_and a b : UInt64)', '(prim bit_and a c : UInt64)', '(prim bit_and b c : UInt64)')}; "
    "((add32 t1 (add32 s0 mj)), (add32 d t1)))))))"
)

JSON = hx('{"id":')
for part, literal in [
    ("id", ',"body":"'),
    ("body", '","created_at":"'),
    ("created", '","author":"'),
    ("author", '","like_count":'),
    ("likes", "}"),
]:
    JSON = f"(prim append {JSON} {part} : Bytes)" if JSON.startswith("0x") else f"(prim append {JSON} {part} : Bytes)"
    JSON = f"(prim append {JSON} {hx(literal)} : Bytes)"

SOURCE = (
    "\\begin{lexlean}{Kernels}\n"
    "\\useglossary{lexlean.std.bool@1.2.0}\n"
    "\\useglossary{lexlean.std.nat@1.2.0}\n"
    "\\title{Natural number addition}\n"
    "\\begin{semanticmodule}\n"
    + "\n".join(
        [
            enum("Phase", ["idle", "reading", "committing"]),
            enum("Event", EVENTS),
            enum("Action", ["nothing", "begin", "commit", "sendAll", "failAll"]),
            table(
                "nextPhase",
                "Phase",
                "Phase",
                [
                    ("idle", ["reading", "idle", "idle", "idle"]),
                    ("reading", ["reading", "committing", "reading", "reading"]),
                    ("committing", ["committing", "committing", "idle", "idle"]),
                ],
            ),
            table(
                "actionOf",
                "Action",
                "Action",
                [
                    ("idle", ["begin", "nothing", "nothing", "nothing"]),
                    ("reading", ["nothing", "commit", "nothing", "nothing"]),
                    ("committing", ["nothing", "nothing", "sendAll", "failAll"]),
                ],
            ),
            "theorem{\n  name: send_only_after_commit,\n  parameters: [phase : Phase, event : Event],\n"
            "  statement: (((actionOf phase event) = (ctor Action.sendAll)) -> ((phase = (ctor Phase.committing)) /\\ (event = (ctor Event.commitOk)))),\n"
            "  proof: induction{\n    branches: [\n      "
            + ",\n      ".join(event_cases(p) for p in ["idle", "reading", "committing"])
            + "\n    ],\n    scrutinee: phase\n  },\n  axioms: [propext]\n}\n",
            "definition{\n  name: decodePhase,\n  parameters: [code : UInt8],\n  result: Phase,\n"
            "  body: (if (prim equal code (0 : UInt8) : Bool) then (ctor Phase.idle) else (if (prim equal code (1 : UInt8) : Bool) then (ctor Phase.reading) else (ctor Phase.committing))),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: decodeEvent,\n  parameters: [code : UInt8],\n  result: Event,\n"
            "  body: (if (prim equal code (0 : UInt8) : Bool) then (ctor Event.request) else (if (prim equal code (1 : UInt8) : Bool) then (ctor Event.batchEnd) else (if (prim equal code (2 : UInt8) : Bool) then (ctor Event.commitOk) else (ctor Event.commitFail)))),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: encodePhase,\n  parameters: [phase : Phase],\n  result: UInt8,\n"
            "  body: (match phase | Phase.idle => (0 : UInt8) | Phase.reading => (1 : UInt8) | Phase.committing => (2 : UInt8)),\n  executable: true\n}\n",
            "definition{\n  name: encodeAction,\n  parameters: [action : Action],\n  result: UInt8,\n"
            "  body: (match action | Action.nothing => (0 : UInt8) | Action.begin => (1 : UInt8) | Action.commit => (2 : UInt8) | Action.sendAll => (3 : UInt8) | Action.failAll => (4 : UInt8)),\n  executable: true\n}\n",
            "definition{\n  name: stepCode,\n  parameters: [phase : UInt8, event : UInt8],\n  result: (UInt8 * UInt8),\n"
            "  body: (let p : Phase := (decodePhase phase); (let e : Event := (decodeEvent event); ((encodePhase (nextPhase p e)), (encodeAction (actionOf p e))))),\n  "
            + EXEC
            + ",\n  production: {effects: [], targets: [rust-core]}\n}\n",
            "definition{\n  name: routeWords,\n  parameters: [w0 : UInt64, w1 : UInt64],\n  result: UInt64,\n  body: "
            + ROUTE
            + ",\n  "
            + EXEC
            + ",\n  production: {effects: [], targets: [rust-core]}\n}\n",
            "definition{\n  name: zeroByte,\n  parameters: [x : UInt64],\n  result: Bool,\n"
            f"  body: (match (prim checked_add (prim bit_and x {M} : UInt64) {M} : (Option UInt64))\n"
            "    | Option.none => false\n"
            f"    | Option.some t => (if (prim equal (prim bit_or (prim bit_or t x : UInt64) {M} : UInt64) {ALL} : Bool) then false else true)),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: needsEscape,\n  parameters: [word : UInt64],\n  result: Bool,\n"
            f"  body: ((zeroByte (prim bit_xor word {u(0x2222222222222222)} : UInt64)) || ((zeroByte (prim bit_xor word {u(0x5C5C5C5C5C5C5C5C)} : UInt64)) || (zeroByte (prim bit_and word {u(0xE0E0E0E0E0E0E0E0)} : UInt64)))),\n  "
            + EXEC
            + ",\n  production: {effects: [], targets: [rust-core]}\n}\n",
            "definition{\n  name: shr,\n  parameters: [x : UInt64, n : UInt32],\n  result: UInt64,\n"
            "  body: (match (prim shift_right x n : (Option UInt64)) | Option.none => (0 : UInt64) | Option.some v => v),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: shl,\n  parameters: [x : UInt64, n : UInt32],\n  result: UInt64,\n"
            "  body: (match (prim shift_left x n : (Option UInt64)) | Option.none => (0 : UInt64) | Option.some v => v),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: rotr32,\n  parameters: [x : UInt64, n : UInt32, m : UInt32],\n  result: UInt64,\n"
            f"  body: (prim bit_and (prim bit_or (shr x n) (shl x m) : UInt64) {LOW32} : UInt64),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: add32,\n  parameters: [x : UInt64, y : UInt64],\n  result: UInt64,\n"
            f"  body: (match (prim checked_add x y : (Option UInt64)) | Option.none => (0 : UInt64) | Option.some v => (prim bit_and v {LOW32} : UInt64)),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: shaRound,\n  parameters: [a : UInt64, b : UInt64, c : UInt64, d : UInt64, e : UInt64, f : UInt64, g : UInt64, h : UInt64, kw : UInt64],\n"
            "  result: (UInt64 * UInt64),\n  body: "
            + SHA_ROUND
            + ",\n  "
            + EXEC
            + ",\n  production: {effects: [], targets: [rust-core]}\n}\n",
            "definition{\n  name: startsWith,\n  parameters: [raw : Bytes, prefix : Bytes, count : Nat],\n  result: Bool,\n"
            "  body: (match (prim slice raw 0 count : (Option Bytes)) | Option.none => false | Option.some head => (prim equal head prefix : Bool)),\n  "
            + EXEC
            + "\n}\n",
            "definition{\n  name: routeBytes,\n  parameters: [raw : Bytes],\n  result: Nat,\n  body: "
            + ROUTE_BYTES
            + ",\n  "
            + EXEC
            + ",\n  production: {effects: [allocation], targets: [rust-std]}\n}\n",
            "definition{\n  name: postJson,\n  parameters: [id : Bytes, body : Bytes, created : Bytes, author : Bytes, likes : Bytes],\n  result: Bytes,\n  body: "
            + JSON
            + ",\n  "
            + EXEC
            + ",\n  production: {effects: [allocation], targets: [rust-std]}\n}\n",
        ]
    )
    + "\\end{semanticmodule}\n\\end{lexlean}\n"
)

target = pathlib.Path(__file__).parent / "kernels" / "src" / "Kernels.lex.tex"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(SOURCE.encode())
print("wrote", target, len(SOURCE), "bytes")
