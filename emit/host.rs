// Writes each file of the archive the certified root returns: a path, a newline, the bytes, a zero byte.
// This and the shell around it are not LexLean, which has no I/O.
fn main() {
    let archive = kern_emit::run(kern_emit::Bytes::lit(b""));
    let out = std::path::PathBuf::from(std::env::args().nth(1).unwrap());
    let mut rest: &[u8] = archive.octets();
    while !rest.is_empty() {
        let line = rest.iter().position(|b| *b == b'\n').unwrap();
        let name = std::str::from_utf8(&rest[..line]).unwrap().to_string();
        rest = &rest[line + 1..];
        let end = rest.iter().position(|b| *b == 0).unwrap();
        let path = out.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, &rest[..end]).unwrap();
        rest = &rest[end + 1..];
    }
}
