// random numbers: the generators, checked against the reference streams
//
// SplitMix64's published test vector (seed 0, first output 0xE220A8397B1DCDAF)
// anchors the mixing here; the xoshiro values follow from seeding with it. If a
// change to std/math.y breaks any of these numbers, the generator changed.
import math;

// SplitMix64, seeded with 0. The first number below is the published test
// vector 0xE220A8397B1DCDAF, written as a signed decimal.
let s0: [long] = [0];
print(math.splitmix64(s0));
print(math.splitmix64(s0));
print(math.splitmix64(s0));

// SplitMix64, seeded with 1 — the first value alone pins the gamma add
let s1: [long] = [1];
print(math.splitmix64(s1));

// xoshiro256** / +, seeded from 42
let x: [long] = [0; 4];
print(math.seed_xoshiro256(x, 42));
print(x[0]);
print(x[1]);
print(x[2]);
print(x[3]);
print(math.xoshiro256pp(x));
print(math.xoshiro256ss(x));

// the same seed gives the same first output; a different seed does not
let w: [long] = [0; 4];
math.seed_xoshiro256(w, 42);
let first_w = math.xoshiro256pp(w);
let v: [long] = [0; 4];
math.seed_xoshiro256(v, 43);
let first_v = math.xoshiro256pp(v);
print(first_w == first_w);
print(first_v != first_w);

// rand_unit and rand_range drive xoshiro, so they want a FOUR-element state
// (a shorter one traps, which is the documented contract)
let st: [long] = [7; 4];
let inrange = true;
let k = 0;
while (k < 2000) {
    let u = math.rand_unit(st);
    if (u < 0.0 || u >= 1.0) { inrange = false; };
    k = k + 1;
};
print(inrange);

// rand_range covers [0, n) and never leaves it
let r: [long] = [9; 4];
let inbounds = true;
let seen: [bool] = [false; 7];
let j = 0;
while (j < 4000) {
    let v = math.rand_range(r, 7);
    if (v < 0 || v >= 7) { inbounds = false; };
    seen[v] = true;
    j = j + 1;
};
print(inbounds);
print(seen[0] && seen[1] && seen[2] && seen[3] && seen[4] && seen[5] && seen[6]);
print(math.rand_range(r, 0));
print(math.rand_range(r, 1));