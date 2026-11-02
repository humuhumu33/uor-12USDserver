//! The `core` suite: one test per scenario in `features/suites/core.feature`.
//!
//! The Lean kernel checks the theorems and `emit/sdk-emit.sh` certifies the root when `just vv` runs. What these tests
//! hold fixed is the claim: each theorem's exact statement, that its axioms stay in the allowed set, and that the
//! server takes the decision from the emitted table instead of deciding some other way. A weakened statement, or a
//! table the server stopped reading, would still verify, and would no longer be the claim.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("crates/conformance is two below the root")
        .to_path_buf()
}

fn read(path: &str) -> String {
    std::fs::read_to_string(root().join(path)).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// The body of the top-level declaration named `name`, up to its closing brace.
fn declaration<'a>(model: &'a str, name: &str) -> &'a str {
    let start = model
        .find(&format!("\n  name: {name},\n"))
        .unwrap_or_else(|| panic!("{name} is not declared"));
    let end = model[start..]
        .find("\n}\n")
        .unwrap_or_else(|| panic!("{name} is not closed"));
    &model[start..start + end]
}

/// Each theorem states exactly this, and rests on no axiom beyond the two the definitions unfold through.
fn assert_theorems(theorems: &[(&str, &str)]) {
    let model = read("emit/core.lex");
    let axioms = read("emit/axioms.json");
    for (name, statement) in theorems {
        let body = declaration(&model, name);
        assert!(
            body.contains(&format!("statement: {statement},")),
            "{name}'s statement changed:\n{body}"
        );
        assert!(!body.contains("sorry"), "{name} must have a proof:\n{body}");
        let observed = axioms.find(&format!("\"{name}\":")).map_or("", |at| {
            &axioms[at..axioms[at..].find(']').map_or(at, |end| at + end)]
        });
        for bad in ["sorryAx", "Classical.choice", "Lean.ofReduceBool"] {
            assert!(!observed.contains(bad), "{name} rests on {bad}");
        }
    }
}

fn assert_server_reads(needles: &[&str]) {
    let server = read("server/src/server.c");
    for needle in needles {
        assert!(
            server.contains(needle),
            "the server must take this decision from the emitted table: {needle}"
        );
    }
}

/// `SV-01`: A batch's responses leave only after its commit, and they are replaced by failures only when the commit fails.
#[test]
fn core_sv_01() {
    assert_theorems(&[
        (
            "send_only_after_commit",
            "((sendAllowed phase event) = true)",
        ),
        (
            "fail_only_after_failed_commit",
            "((failAllowed phase event) = true)",
        ),
        (
            "committing_follows_commit",
            "((committingFollowsCommit phase event) = true)",
        ),
    ]);
    assert_server_reads(&[
        "ACTION_OF[batch_phase][event]",
        "NEXT_PHASE[batch_phase][event]",
        "batch_step(EVENT_BATCH_END) != ACTION_COMMIT",
        "action != ACTION_SEND_ALL && action != ACTION_FAIL_ALL",
    ]);
    let server = read("server/src/server.c");
    assert_eq!(
        server.matches("prepare_send(r);").count(),
        1,
        "run_list must be the only place a response is sent"
    );
    // A send above the commit would keep every string above and pass the 42 sequential tests.
    let run_list = &server[server.find("static uint32_t run_list").expect("run_list")..];
    let commit = run_list
        .find("batch_step(EVENT_BATCH_END)")
        .expect("the commit step");
    let decided = run_list
        .find("batch_step(commit_failed")
        .expect("the result step");
    let send = run_list.find("prepare_send(r);").expect("the send");
    assert!(
        commit < decided && decided < send,
        "the sends must come after the commit and its result"
    );
}

/// `SV-02`: Only POST writes, every write needs a token, and an unknown method is not found.
#[test]
fn core_sv_02() {
    assert_theorems(&[
        (
            "every_write_needs_a_token",
            "((isWrite route) = (needsAuth route))",
        ),
        (
            "only_post_writes",
            "((writeComesFromPost method shape) = true)",
        ),
        (
            "unknown_methods_are_not_found",
            "((routeOf (ctor Method.other) shape) = (ctor Route.notFound))",
        ),
    ]);
    assert_server_reads(&[
        "ROUTE_OF[method][path_shape(path, path_len)]",
        "if (ROUTE_NEEDS_TOKEN[route]) {",
    ]);
}

/// `SV-03`: While the hold queue has room, the hold table holds no read on a connection with nothing held, every write at a closed gate, and every later request on a held connection.
#[test]
fn core_sv_03() {
    assert_theorems(&[
        (
            "reads_go_on_while_writes_wait",
            "((shouldHold room gateClosed (ctor Flag.no) (ctor Flag.no)) = (ctor Flag.no))",
        ),
        (
            "a_held_connection_keeps_its_order",
            "((shouldHold (ctor Flag.yes) gateClosed write (ctor Flag.yes)) = (ctor Flag.yes))",
        ),
        (
            "a_closed_gate_holds_writes",
            "((shouldHold (ctor Flag.yes) (ctor Flag.yes) (ctor Flag.yes) connectionHeld) = (ctor Flag.yes))",
        ),
        (
            "an_open_gate_holds_nothing_new",
            "((shouldHold room (ctor Flag.no) write (ctor Flag.no)) = (ctor Flag.no))",
        ),
        (
            "a_full_hold_queue_holds_nothing",
            "((shouldHold (ctor Flag.no) gateClosed write connectionHeld) = (ctor Flag.no))",
        ),
    ]);
    assert_server_reads(&["return SHOULD_HOLD[(room ? 8 : 0) | (gate_closed ? 4 : 0) | (write ? 2 : 0) | (connection_held ? 1 : 0)];"]);
}

/// `SV-04`: The write pause closes at its limit and opens when the log is copied or the wait times out.
#[test]
fn core_sv_04() {
    assert_theorems(&[
        (
            "the_gate_stays_closed_until_the_log_is_copied",
            "((gateNext (ctor Flag.yes) overLimit (ctor Flag.no) (ctor Flag.no)) = (ctor Flag.yes))",
        ),
        (
            "the_gate_closes_at_the_limit",
            "((gateNext (ctor Flag.no) (ctor Flag.yes) copied timedOut) = (ctor Flag.yes))",
        ),
        (
            "the_gate_opens_when_the_log_is_copied",
            "((gateNext (ctor Flag.yes) overLimit (ctor Flag.yes) timedOut) = (ctor Flag.no))",
        ),
        (
            "a_timeout_always_opens_the_gate",
            "((gateNext (ctor Flag.yes) overLimit copied (ctor Flag.yes)) = (ctor Flag.no))",
        ),
    ]);
    assert_server_reads(&[
        "GATE_NEXT[(wal_gate ? 8 : 0) | (frames >= WAL_GATE_FRAMES ? 4 : 0)]",
        "!GATE_NEXT[8 | (copied ? 2 : 0) | (timed_out ? 1 : 0)]",
    ]);
}

/// `SV-05`: In the failure table, only an internal failure is a server error.
#[test]
fn core_sv_05() {
    assert_theorems(&[(
        "only_an_internal_failure_is_a_server_error",
        "((isServerStatus (statusOf failure)) = (isInternal failure))",
    )]);
    let server = read("server/src/server.c");
    for row in 0..10 {
        assert!(
            server.contains(&format!("FAILURE_ROW_{row},")),
            "canned_setup must build failure {row} from the emitted table"
        );
    }
    for status in ["\"HTTP/1.1 4", "{404,", "{401,", "{400,"] {
        assert!(
            !server.contains(status),
            "a failure status must not be written by hand: {status}"
        );
    }
}

/// `SV-06`: A quote, a backslash and the control bytes are escaped at the checked values, and the emitted table matches the rule for all 256 bytes.
#[test]
fn core_sv_06() {
    assert_theorems(&[
        (
            "a_quote_is_escaped",
            "((escapeClass (34 : UInt8)) = (ctor EscapeClass.backslash))",
        ),
        (
            "a_backslash_is_escaped",
            "((escapeClass (92 : UInt8)) = (ctor EscapeClass.backslash))",
        ),
        (
            "the_first_control_byte_is_escaped",
            "((escapeClass (0 : UInt8)) = (ctor EscapeClass.unicode))",
        ),
        (
            "the_last_control_byte_is_escaped",
            "((escapeClass (31 : UInt8)) = (ctor EscapeClass.unicode))",
        ),
        (
            "a_space_is_plain",
            "((escapeClass (32 : UInt8)) = (ctor EscapeClass.plain))",
        ),
        (
            "the_top_byte_is_plain",
            "((escapeClass (255 : UInt8)) = (ctor EscapeClass.plain))",
        ),
    ]);
    assert_server_reads(&["switch (ESCAPE_CLASS[c]) {", "word_needs_escape(word)"]);
    let test = read("server/src/core_test.c");
    assert!(
        test.contains("byte < 256")
            && test.contains("lane < 8")
            && test.contains("word_needs_escape(word) == needs"),
        "core_test must check every byte in every lane"
    );
}

fn server_files(dir: &Path, base: &Path, found: &mut BTreeSet<String>) {
    for entry in std::fs::read_dir(dir).expect("server directory") {
        let path = entry.expect("entry").path();
        let name = path
            .strip_prefix(base)
            .expect("under server")
            .to_string_lossy()
            .replace('\\', "/");
        if path.is_dir() {
            if name != "bin" && name != "vendor" {
                server_files(&path, base, found);
            }
        } else {
            found.insert(name);
        }
    }
}

/// `SV-07`: Every file in server is what the certified root writes, and the committed module is not stale.
#[test]
fn core_sv_07() {
    let script = read("emit/sdk-emit.sh");
    let line = script
        .lines()
        .find_map(|line| line.strip_prefix("FILES=\""))
        .and_then(|rest| rest.strip_suffix('"'))
        .expect("the script lists the files it compares");
    let compared: BTreeSet<String> = line.split(' ').map(str::to_string).collect();
    let mut present = BTreeSet::new();
    let base = root().join("server");
    server_files(&base, &base, &mut present);
    assert_eq!(
        compared, present,
        "every file in server must be compared with what the root writes"
    );

    assert!(
        script.contains("is_fresh || fresh=0") && script.contains("[ \"$fresh\" = 1 ] || bad=1"),
        "a stale module must fail the gate"
    );
    assert!(
        script.contains("exit \"$bad\""),
        "the script must report what it found"
    );

    let recipes = read("Justfile");
    let gate = recipes
        .lines()
        .find(|line| line.starts_with("vv:"))
        .expect("the vv recipe");
    assert!(
        gate.contains(" emit"),
        "just vv must run the emit gate: {gate}"
    );
    assert!(
        recipes.contains("bash emit/sdk-emit.sh"),
        "the emit recipe must run the script"
    );

    let module = read("emit/project/src/Emit.lex.tex");
    assert!(
        module.contains("name: emitSource,") && module.contains("targets: [rust-std]"),
        "the committed module must hold the production root"
    );
}

/// `SV-08`: The box's build checks the theorems and every file with official Lean alone, and stops on a false, weakened or deleted theorem, a sorry, an added axiom or an edited file.
#[test]
fn core_sv_08() {
    let build = read("server/build.sh");
    assert!(
        build.contains("lake build --wfail"),
        "warnings must fail the build, or a sorry passes"
    );
    assert!(
        build.contains("lean --run Write.lean ../generated"),
        "the program must write the files on the box"
    );
    assert!(
        build.contains("cmp \"$name\" \"generated/$name\""),
        "a file that differs from what the program writes must stop the build"
    );
    assert!(
        build.contains("for name in src/server.c src/core.h src/core_test.c build.sh"),
        "the readable C must be compared with what the program wrote"
    );
    assert!(
        build.contains("bin/core_test"),
        "the tables must be tested on the box"
    );
    let install = read("server/install.sh");
    assert!(
        install.contains("LEAN_SHA256=") && install.contains("sha256sum -c -"),
        "the Lean the box installs must be pinned by digest"
    );
    let lakefile = read("emit/submission/lakefile.toml");
    assert!(
        lakefile.contains("\"Claims\""),
        "the build must include the restated claims"
    );
    let claims = read("emit/submission/Claims.lean");
    let model = read("emit/core.lex");
    let theorems = model.matches("theorem{").count();
    assert_eq!(
        claims.matches("#check_axioms ").count() - 1,
        theorems,
        "every theorem must have its axioms checked"
    );
    let plant = read("emit/submission/plant.sh");
    for defect in [
        "false_theorem",
        "theorem_left_as_sorry",
        "readme_edited_alone",
        "UNTOUCHED",
    ] {
        assert!(plant.contains(defect), "plant.sh must try {defect}");
    }
}
