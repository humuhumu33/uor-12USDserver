#![no_std]
#![forbid(unsafe_code)]
use core::cmp::Ordering;
use core::sync::atomic::{AtomicU64, Ordering as Memory};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Overflow;
pub type R<T> = Result<T, Overflow>;

static WORK: AtomicU64 = AtomicU64::new(0);
pub fn tick(units: u64) { WORK.fetch_add(units, Memory::Relaxed); }
pub fn work() -> u64 { WORK.load(Memory::Relaxed) }

pub fn nat_add(a: u64, b: u64) -> R<u64> { a.checked_add(b).ok_or(Overflow) }
pub fn nat_sub(a: u64, b: u64) -> u64 { a.saturating_sub(b) }
pub fn nat_mul(a: u64, b: u64) -> R<u64> { a.checked_mul(b).ok_or(Overflow) }
pub fn nat_quot(a: u64, b: u64, z: u64) -> u64 { a.checked_div(b).unwrap_or(z) }
pub fn nat_rem(a: u64, b: u64, z: u64) -> u64 { a.checked_rem(b).unwrap_or(z) }
pub fn nat_eq(a: u64, b: u64) -> bool { a == b }
pub fn nat_le(a: u64, b: u64) -> bool { a <= b }
pub fn nat_lt(a: u64, b: u64) -> bool { a < b }
pub fn nat_succ(a: u64) -> R<u64> { a.checked_add(1).ok_or(Overflow) }
pub fn int_add(a: i64, b: i64) -> R<i64> { a.checked_add(b).ok_or(Overflow) }
pub fn int_sub(a: i64, b: i64) -> R<i64> { a.checked_sub(b).ok_or(Overflow) }
pub fn int_mul(a: i64, b: i64) -> R<i64> { a.checked_mul(b).ok_or(Overflow) }
pub fn int_neg(a: i64) -> R<i64> { a.checked_neg().ok_or(Overflow) }
pub fn int_quot(a: i64, b: i64, z: i64) -> R<i64> { if b == 0 { Ok(z) } else { a.checked_div(b).ok_or(Overflow) } }
pub fn int_rem(a: i64, b: i64, z: i64) -> i64 { if b == 0 { z } else { a.wrapping_rem(b) } }
pub fn bool_not(a: bool) -> bool { !a }
pub fn bool_and(a: bool, b: bool) -> bool { a && b }
pub fn bool_or(a: bool, b: bool) -> bool { a || b }

pub trait Same { fn same(&self, other: &Self) -> bool; }
pub trait Key { fn key(&self, other: &Self) -> Ordering; }
macro_rules! scalar {
    ($($t:ty),*) => { $(
        impl Same for $t { fn same(&self, other: &Self) -> bool { self == other } }
        impl Key for $t { fn key(&self, other: &Self) -> Ordering { self.cmp(other) } }
    )* };
}
scalar!(bool, u8, u16, u32, u64, i8, i16, i32, i64);
impl Same for Ordering { fn same(&self, other: &Self) -> bool { self == other } }
impl<A: Key, B: Key> Key for (A, B) {
    fn key(&self, other: &Self) -> Ordering {
        match self.0.key(&other.0) { Ordering::Equal => self.1.key(&other.1), decided => decided }
    }
}
pub fn equal<T: Same>(a: T, b: T) -> bool { a.same(&b) }
pub fn compare<T: Key>(a: T, b: T) -> Ordering { a.key(&b) }

macro_rules! fixed {
    ($m:ident, $t:ident) => {
        pub mod $m {
            pub fn checked_add(a: $t, b: $t) -> Option<$t> { a.checked_add(b) }
            pub fn checked_sub(a: $t, b: $t) -> Option<$t> { a.checked_sub(b) }
            pub fn checked_mul(a: $t, b: $t) -> Option<$t> { a.checked_mul(b) }
            pub fn checked_quot(a: $t, b: $t) -> Option<$t> { a.checked_div(b) }
            pub fn bit_and(a: $t, b: $t) -> $t { a & b }
            pub fn bit_or(a: $t, b: $t) -> $t { a | b }
            pub fn bit_xor(a: $t, b: $t) -> $t { a ^ b }
            pub fn bit_not(a: $t) -> $t { !a }
            pub fn shift_left(a: $t, amount: u32) -> Option<$t> { if amount < $t::BITS { Some(a.wrapping_shl(amount)) } else { None } }
            pub fn shift_right(a: $t, amount: u32) -> Option<$t> { if amount < $t::BITS { Some(a.wrapping_shr(amount)) } else { None } }
            pub fn convert(a: i128) -> Option<$t> { $t::try_from(a).ok() }
        }
    };
}
fixed!(fixed_u8, u8); fixed!(fixed_u16, u16); fixed!(fixed_u32, u32); fixed!(fixed_u64, u64);
fixed!(fixed_i8, i8); fixed!(fixed_i16, i16); fixed!(fixed_i32, i32); fixed!(fixed_i64, i64);
pub fn checked_neg_i8(a: i8) -> Option<i8> { a.checked_neg() }
pub fn checked_neg_i16(a: i16) -> Option<i16> { a.checked_neg() }
pub fn checked_neg_i32(a: i32) -> Option<i32> { a.checked_neg() }
pub fn checked_neg_i64(a: i64) -> Option<i64> { a.checked_neg() }

#[derive(Clone)]
pub enum Adt0 {
    C0,
    C1,
    C2,
}

#[derive(Clone)]
pub enum Adt1 {
    C0,
    C1,
    C2,
    C3,
}

#[derive(Clone)]
pub enum Adt2 {
    C0,
    C1,
    C2,
    C3,
    C4,
}

pub fn f0(v0: u8, v1: u8) -> (u8, u8) {
    let v2: Adt0 = f1(v0);
    let v3: Adt1 = f2(v1);
    (f3(f4(v2.clone(), v3.clone())), f5(f6(v2, v3)))
}

pub fn f1(v0: u8) -> Adt0 {
    let a1 = v0;
    let a2 = 0u8;
    if equal(a1, a2) {
        Adt0::C0
    } else {
        let a3 = v0;
        let a4 = 1u8;
        if equal(a3, a4) {
            Adt0::C1
        } else {
            Adt0::C2
        }
    }
}

pub fn f2(v0: u8) -> Adt1 {
    let a5 = v0;
    let a6 = 0u8;
    if equal(a5, a6) {
        Adt1::C0
    } else {
        let a7 = v0;
        let a8 = 1u8;
        if equal(a7, a8) {
            Adt1::C1
        } else {
            let a9 = v0;
            let a10 = 2u8;
            if equal(a9, a10) {
                Adt1::C2
            } else {
                Adt1::C3
            }
        }
    }
}

pub fn f3(v0: Adt0) -> u8 {
    let m11 = v0;
    match m11 {
        Adt0::C0 => {
            0u8
        }
        Adt0::C1 => {
            1u8
        }
        Adt0::C2 => {
            2u8
        }
    }
}

pub fn f4(v0: Adt0, v1: Adt1) -> Adt0 {
    let m12 = v0;
    match m12 {
        Adt0::C0 => {
            let m13 = v1;
            match m13 {
                Adt1::C0 => {
                    Adt0::C1
                }
                Adt1::C1 => {
                    Adt0::C0
                }
                Adt1::C2 => {
                    Adt0::C0
                }
                Adt1::C3 => {
                    Adt0::C0
                }
            }
        }
        Adt0::C1 => {
            let m14 = v1;
            match m14 {
                Adt1::C0 => {
                    Adt0::C1
                }
                Adt1::C1 => {
                    Adt0::C2
                }
                Adt1::C2 => {
                    Adt0::C1
                }
                Adt1::C3 => {
                    Adt0::C1
                }
            }
        }
        Adt0::C2 => {
            let m15 = v1;
            match m15 {
                Adt1::C0 => {
                    Adt0::C2
                }
                Adt1::C1 => {
                    Adt0::C2
                }
                Adt1::C2 => {
                    Adt0::C0
                }
                Adt1::C3 => {
                    Adt0::C0
                }
            }
        }
    }
}

pub fn f5(v0: Adt2) -> u8 {
    let m16 = v0;
    match m16 {
        Adt2::C0 => {
            0u8
        }
        Adt2::C1 => {
            1u8
        }
        Adt2::C2 => {
            2u8
        }
        Adt2::C3 => {
            3u8
        }
        Adt2::C4 => {
            4u8
        }
    }
}

pub fn f6(v0: Adt0, v1: Adt1) -> Adt2 {
    let m17 = v0;
    match m17 {
        Adt0::C0 => {
            let m18 = v1;
            match m18 {
                Adt1::C0 => {
                    Adt2::C1
                }
                Adt1::C1 => {
                    Adt2::C0
                }
                Adt1::C2 => {
                    Adt2::C0
                }
                Adt1::C3 => {
                    Adt2::C0
                }
            }
        }
        Adt0::C1 => {
            let m19 = v1;
            match m19 {
                Adt1::C0 => {
                    Adt2::C0
                }
                Adt1::C1 => {
                    Adt2::C2
                }
                Adt1::C2 => {
                    Adt2::C0
                }
                Adt1::C3 => {
                    Adt2::C0
                }
            }
        }
        Adt0::C2 => {
            let m20 = v1;
            match m20 {
                Adt1::C0 => {
                    Adt2::C0
                }
                Adt1::C1 => {
                    Adt2::C0
                }
                Adt1::C2 => {
                    Adt2::C3
                }
                Adt1::C3 => {
                    Adt2::C4
                }
            }
        }
    }
}

pub fn run(p0: u8, p1: u8) -> (u8, u8) {
    f0(p0, p1)
}
