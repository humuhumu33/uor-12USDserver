//! Generated LexLean kernels against the same logic written by hand, interleaved so machine drift hits both.
use std::alloc::{GlobalAlloc, Layout, System};
use std::hint::black_box;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Instant;

struct Counting;
static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Relaxed);
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        System.dealloc(pointer, layout)
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

extern "C" {
    fn shim_mix(a: u64, b: u64) -> u64;
    fn shim_loop(n: u64, seed: u64) -> u64;
}

fn pass(iterations: u64, body: &mut dyn FnMut(u64) -> u64) -> (f64, f64) {
    let allocations = ALLOCATIONS.load(Relaxed);
    let start = Instant::now();
    let mut sink = 0u64;
    for i in 0..iterations {
        sink = sink.wrapping_add(body(i));
    }
    let elapsed = start.elapsed().as_nanos() as f64;
    black_box(sink);
    (elapsed / iterations as f64, (ALLOCATIONS.load(Relaxed) - allocations) as f64 / iterations as f64)
}

fn compare(name: &str, iterations: u64, generated: &mut dyn FnMut(u64) -> u64, written: &mut dyn FnMut(u64) -> u64) {
    let (mut ours, mut theirs) = (Vec::new(), Vec::new());
    let (mut ours_alloc, mut theirs_alloc) = (0.0, 0.0);
    for _ in 0..15 {
        let a = pass(iterations, generated);
        let b = pass(iterations, written);
        ours.push(a.0);
        theirs.push(b.0);
        ours_alloc = a.1;
        theirs_alloc = b.1;
    }
    ours.sort_by(f64::total_cmp);
    theirs.sort_by(f64::total_cmp);
    let (g, h) = (ours[7], theirs[7]);
    println!(
        "BENCH {name:<22} generated {g:>9.1} ns [{:>8.1}..{:>8.1}] {ours_alloc:>5.1} allocs | handwritten {h:>8.1} ns [{:>8.1}..{:>8.1}] {theirs_alloc:>4.1} allocs | ratio {:>7.2}",
        ours[0], ours[14], theirs[0], theirs[14], g / h.max(0.01)
    );
}

const LINES: [&[u8]; 7] = [
    b"GET /feed HTTP/1.1\r\nHost: a\r\n\r\n",
    b"GET /health HTTP/1.1\r\nHost: a\r\n\r\n",
    b"GET /posts/1234 HTTP/1.1\r\nHost: a\r\n\r\n",
    b"POST /posts HTTP/1.1\r\nHost: a\r\n\r\n",
    b"POST /posts/1234/like HTTP/1.1\r\nHost: a\r\n\r\n",
    b"GET /nothing HTTP/1.1\r\nHost: a\r\n\r\n",
    b"GET /posts/9 HTTP/1.1\r\nHost: a\r\nUser-Agent: k6/1.0 (https://k6.io/)\r\nAccept-Encoding: identity\r\n\r\n",
];

fn words(line: &[u8]) -> (u64, u64) {
    (u64::from_le_bytes(line[0..8].try_into().unwrap()), u64::from_le_bytes(line[8..16].try_into().unwrap()))
}

fn route_words_by_hand(w0: u64, w1: u64) -> u64 {
    const GET_FEE: u64 = u64::from_le_bytes(*b"GET /fee");
    const D_HTTP: u64 = u64::from_le_bytes(*b"d HTTP/1");
    const GET_HEA: u64 = u64::from_le_bytes(*b"GET /hea");
    const LTH_HTTP: u64 = u64::from_le_bytes(*b"lth HTTP");
    const GET_POS: u64 = u64::from_le_bytes(*b"GET /pos");
    const POST_PO: u64 = u64::from_le_bytes(*b"POST /po");
    const STS_HTTP: u64 = u64::from_le_bytes(*b"sts HTTP");
    if w0 == GET_FEE && w1 == D_HTTP {
        1
    } else if w0 == GET_HEA && w1 == LTH_HTTP {
        2
    } else if w0 == GET_POS && w1 & 0xFF_FFFF == 3109748 {
        3
    } else if w0 == POST_PO && w1 == STS_HTTP {
        4
    } else if w0 == POST_PO && w1 & 0xFFFF_FFFF == 796095603 {
        5
    } else {
        0
    }
}

fn route_bytes_by_hand(line: &[u8]) -> u64 {
    if line.starts_with(b"GET /feed HTTP/1") {
        1
    } else if line.starts_with(b"GET /health HTTP") {
        2
    } else if line.starts_with(b"GET /posts/") {
        3
    } else if line.starts_with(b"POST /posts HTTP") {
        4
    } else if line.starts_with(b"POST /posts/") {
        5
    } else {
        0
    }
}

fn step_by_hand(phase: u8, event: u8) -> (u8, u8) {
    match (phase, event) {
        (0, 0) => (1, 1),
        (0, _) => (0, 0),
        (1, 0) => (1, 0),
        (1, 1) => (2, 2),
        (1, _) => (1, 0),
        (_, 2) => (0, 3),
        (_, 3) => (0, 4),
        (_, _) => (2, 0),
    }
}

#[allow(clippy::too_many_arguments)]
fn sha_round_by_hand(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32, kw: u32) -> (u32, u32) {
    let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
    let ch = (e & f) ^ (!e & g);
    let t1 = h.wrapping_add(s1).wrapping_add(ch).wrapping_add(kw);
    let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
    let mj = (a & b) ^ (a & c) ^ (b & c);
    (t1.wrapping_add(s0.wrapping_add(mj)), d.wrapping_add(t1))
}

fn next(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    *state
}

fn main() {
    // The comparison means nothing unless both sides compute the same function.
    for phase in 0..3u8 {
        for event in 0..4u8 {
            assert_eq!(kern_step::run(phase, event), step_by_hand(phase, event), "step {phase} {event}");
        }
    }
    for line in LINES {
        let (w0, w1) = words(line);
        assert_eq!(kern_route_words::run(w0, w1), route_words_by_hand(w0, w1), "route words");
        assert_eq!(kern_route_bytes::run(kern_route_bytes::Bytes::lit(line)), route_bytes_by_hand(line), "route bytes");
    }
    let mut seed = 0x1234_5678_9ABC_DEF1u64;
    let mut sample = |state: &mut u64| [next(state) as u32, next(state) as u32, next(state) as u32, next(state) as u32, next(state) as u32, next(state) as u32, next(state) as u32, next(state) as u32, next(state) as u32];
    for _ in 0..100_000 {
        let x = sample(&mut seed);
        let (p, q) = kern_sha_round::run(x[0] as u64, x[1] as u64, x[2] as u64, x[3] as u64, x[4] as u64, x[5] as u64, x[6] as u64, x[7] as u64, x[8] as u64);
        let (r, s) = sha_round_by_hand(x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7], x[8]);
        assert_eq!((p, q), (r as u64, s as u64), "sha round");
    }
    let fields: [&[u8]; 5] = [b"123456", b"demo_user says hi at 2026-11-01T21:50:40.123Z (VU 123456, iter 12) and a bit more", b"2026-11-01T21:50:40.123Z", b"demo_user", b"42"];
    let expected = br#"{"id":123456,"body":"demo_user says hi at 2026-11-01T21:50:40.123Z (VU 123456, iter 12) and a bit more","created_at":"2026-11-01T21:50:40.123Z","author":"demo_user","like_count":42}"#;
    use kern_post_json::Bytes as JsonBytes;
    let post = |f: &[&[u8]; 5]| kern_post_json::run(JsonBytes::lit(f[0]), JsonBytes::lit(f[1]), JsonBytes::lit(f[2]), JsonBytes::lit(f[3]), JsonBytes::lit(f[4]));
    assert_eq!(post(&fields).octets(), &expected[..], "post json");
    println!("EQUIVALENCE ok: step, route words, route bytes, sha round (100000 random), post json");

    compare("step", 20_000_000, &mut |i| {
        let (p, a) = kern_step::run(black_box((i % 3) as u8), black_box((i % 4) as u8));
        p as u64 + a as u64
    }, &mut |i| {
        let (p, a) = step_by_hand(black_box((i % 3) as u8), black_box((i % 4) as u8));
        p as u64 + a as u64
    });
    let split: Vec<(u64, u64)> = LINES.iter().map(|l| words(l)).collect();
    compare("route words", 20_000_000, &mut |i| {
        let (a, b) = split[(i % 7) as usize];
        kern_route_words::run(black_box(a), black_box(b))
    }, &mut |i| {
        let (a, b) = split[(i % 7) as usize];
        route_words_by_hand(black_box(a), black_box(b))
    });
    let mut state = 88172645463325252u64;
    let inputs: Vec<[u32; 9]> = (0..1024).map(|_| sample(&mut state)).collect();
    compare("sha round", 5_000_000, &mut |i| {
        let x = inputs[(i % 1024) as usize];
        let (p, q) = kern_sha_round::run(black_box(x[0] as u64), x[1] as u64, x[2] as u64, x[3] as u64, x[4] as u64, x[5] as u64, x[6] as u64, x[7] as u64, x[8] as u64);
        p ^ q
    }, &mut |i| {
        let x = inputs[(i % 1024) as usize];
        let (p, q) = sha_round_by_hand(black_box(x[0]), x[1], x[2], x[3], x[4], x[5], x[6], x[7], x[8]);
        (p ^ q) as u64
    });
    compare("route bytes", 1_000_000, &mut |i| {
        kern_route_bytes::run(kern_route_bytes::Bytes::lit(black_box(LINES[(i % 7) as usize])))
    }, &mut |i| route_bytes_by_hand(black_box(LINES[(i % 7) as usize])));
    let mut buffer: Vec<u8> = Vec::with_capacity(4096);
    compare("post json", 400_000, &mut |_| post(black_box(&fields)).octets().len() as u64, &mut |_| {
        buffer.clear();
        let f = black_box(&fields);
        buffer.extend_from_slice(br#"{"id":"#);
        buffer.extend_from_slice(f[0]);
        buffer.extend_from_slice(br#","body":""#);
        buffer.extend_from_slice(f[1]);
        buffer.extend_from_slice(br#"","created_at":""#);
        buffer.extend_from_slice(f[2]);
        buffer.extend_from_slice(br#"","author":""#);
        buffer.extend_from_slice(f[3]);
        buffer.extend_from_slice(br#"","like_count":"#);
        buffer.extend_from_slice(f[4]);
        buffer.push(b'}');
        buffer.len() as u64
    });
    let mut v = 7u64;
    let rust_side = pass(50_000_000, &mut |i| {
        v = unsafe { shim_mix(black_box(v), i) };
        v
    });
    let start = Instant::now();
    black_box(unsafe { shim_loop(black_box(50_000_000), 7) });
    println!(
        "BOUNDARY call from Rust {:.2} ns, the same call from C {:.2} ns",
        rust_side.0,
        start.elapsed().as_nanos() as f64 / 50_000_000.0
    );
}
