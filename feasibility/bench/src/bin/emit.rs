fn main() {
    let source = kern_emit::run(kern_emit::Bytes::lit(b""));
    std::fs::write(std::env::args().nth(1).expect("output path"), source.octets()).expect("write");
}
