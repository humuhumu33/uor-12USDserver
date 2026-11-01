use std::{env, path::Path, process::Command};

fn run(command: &mut Command) {
    assert!(command.status().expect("spawn").success(), "{command:?} failed");
}

fn main() {
    let out = env::var("OUT_DIR").unwrap();
    let object = Path::new(&out).join("shim.o");
    run(Command::new("cc").args(["-O2", "-c", "shim.c", "-o"]).arg(&object));
    run(Command::new("ar").arg("crs").arg(Path::new(&out).join("libshim.a")).arg(&object));
    println!("cargo:rustc-link-search=native={out}");
    println!("cargo:rustc-link-lib=static=shim");
    println!("cargo:rerun-if-changed=shim.c");
}
