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

pub fn f0(v0: u64, v1: u64, v2: u64, v3: u64, v4: u64, v5: u64, v6: u64, v7: u64, v8: u64) -> (u64, u64) {
    let v9: u64 = {
        let a3 = {
            let a1 = f1(v4, 6u32, 26u32);
            let a2 = f1(v4, 11u32, 21u32);
            fixed_u64::bit_xor(a1, a2)
        };
        let a4 = f1(v4, 25u32, 7u32);
        fixed_u64::bit_xor(a3, a4)
    };
    let v10: u64 = {
        let a10 = {
            let a5 = v4;
            let a6 = v5;
            fixed_u64::bit_and(a5, a6)
        };
        let a11 = {
            let a8 = {
                let a7 = v4;
                fixed_u64::bit_not(a7)
            };
            let a9 = v6;
            fixed_u64::bit_and(a8, a9)
        };
        fixed_u64::bit_xor(a10, a11)
    };
    let v11: u64 = f2(f2(f2(v7, v9), {
        let a12 = v10;
        let a13 = 4294967295u64;
        fixed_u64::bit_and(a12, a13)
    }), v8);
    let v12: u64 = {
        let a16 = {
            let a14 = f1(v0, 2u32, 30u32);
            let a15 = f1(v0, 13u32, 19u32);
            fixed_u64::bit_xor(a14, a15)
        };
        let a17 = f1(v0, 22u32, 10u32);
        fixed_u64::bit_xor(a16, a17)
    };
    let v13: u64 = {
        let a26 = {
            let a22 = {
                let a18 = v0;
                let a19 = v1;
                fixed_u64::bit_and(a18, a19)
            };
            let a23 = {
                let a20 = v0;
                let a21 = v2;
                fixed_u64::bit_and(a20, a21)
            };
            fixed_u64::bit_xor(a22, a23)
        };
        let a27 = {
            let a24 = v1;
            let a25 = v2;
            fixed_u64::bit_and(a24, a25)
        };
        fixed_u64::bit_xor(a26, a27)
    };
    (f2(v11, f2(v12, v13)), f2(v3, v11))
}

pub fn f1(v0: u64, v1: u32, v2: u32) -> u64 {
    let a30 = {
        let a28 = f3(v0, v1);
        let a29 = f4(v0, v2);
        fixed_u64::bit_or(a28, a29)
    };
    let a31 = 4294967295u64;
    fixed_u64::bit_and(a30, a31)
}

pub fn f2(v0: u64, v1: u64) -> u64 {
    let m34 = {
        let a32 = v0;
        let a33 = v1;
        fixed_u64::checked_add(a32, a33)
    };
    match m34 {
        None => {
            0u64
        }
        Some(v2) => {
            let a35 = v2;
            let a36 = 4294967295u64;
            fixed_u64::bit_and(a35, a36)
        }
    }
}

pub fn f3(v0: u64, v1: u32) -> u64 {
    let m39 = {
        let a37 = v0;
        let a38 = v1;
        fixed_u64::shift_right(a37, a38)
    };
    match m39 {
        None => {
            0u64
        }
        Some(v2) => {
            v2
        }
    }
}

pub fn f4(v0: u64, v1: u32) -> u64 {
    let m42 = {
        let a40 = v0;
        let a41 = v1;
        fixed_u64::shift_left(a40, a41)
    };
    match m42 {
        None => {
            0u64
        }
        Some(v2) => {
            v2
        }
    }
}

pub fn run(p0: u64, p1: u64, p2: u64, p3: u64, p4: u64, p5: u64, p6: u64, p7: u64, p8: u64) -> (u64, u64) {
    f0(p0, p1, p2, p3, p4, p5, p6, p7, p8)
}
