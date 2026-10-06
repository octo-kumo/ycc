// rotl: rotate left, and the count it accepts.
//
// rotl had NO case anywhere until now, which is why a trap in it went
// unnoticed for as long as it did. The function was `x << k | x >>> (64 - k)`
// under a comment saying "for 1 <= k <= 63"; k = 0 and k = 64 happened to be
// right (x | 0 and 0 | x), so the function read as though it took 0, while
// k = 65 KILLED THE PROGRAM, because 64 - 65 is -1 and a negative shift count
// traps. A rotation whose count is out of range now wraps, which is what the
// instruction does -- ROL masks its count to six bits.
//
// Every count below is checked against the identity rotl(x, k) ==
// rotl(x, k mod 64), so raising the modulus above 64 is a diff here, and so is
// any change that makes a multiple of 64 stop being the identity.

import math;

def same(a: long, b: long) -> bool {
    a == b
};

// One word with bits in every position, so a rotation that drops or duplicates
// one shows up as a different number rather than as a lucky match.
let x: long = 0x0123456789abcdef;
let inv: long = 0xfedcba9876543210;
let one: long = 1;
let high: long = 0x8000000000000000;

// The identity at every multiple of 64, and 0 and 64 in particular -- the two
// the old form got right by accident rather than by construction.
print(same(math.rotl(x, 0), x));
print(same(math.rotl(x, 64), x));
print(same(math.rotl(x, 128), x));
print(same(math.rotl(x, 0 - 64), x));
print(same(math.rotl(x, 0 - 128), x));

// A single set bit moves to its own position, which is the clearest statement
// of what a rotation is: bit k goes to bit (k + n) mod 64.
print(math.rotl(one, 1));
print(math.rotl(one, 63));
print(math.rotl(one, 64));
print(math.rotl(one, 65));
print(math.rotl(high, 1));
print(math.rotl(high, 63));

// Rotating left by n then right by n is the identity, for n on both sides of
// the word and for counts that needed reducing.
print(same(math.rotl(math.rotl(x, 17), 0 - 17), x));
print(same(math.rotl(math.rotl(x, 17), 47), x));
print(same(math.rotl(math.rotl(x, 63), 1), x));

// A rotation of the whole word by 32 is its own inverse, and for a word whose
// halves differ it is the swap of them.
print(math.rotl(x, 32));
print(math.rotl(inv, 32));

// The counts that used to kill the program, and their neighbours: 65 and -1
// both reduce, and reduce to the right thing.
print(math.rotl(x, 65));
print(math.rotl(x, 129));
print(math.rotl(x, 0 - 1));
print(math.rotl(x, 0 - 65));
print(same(math.rotl(x, 65), math.rotl(x, 1)));
print(same(math.rotl(x, 0 - 1), math.rotl(x, 63)));

// And the shape the module's own generators depend on: 7 and 45 are the two
// xoshiro256 rotations, and they must be untouched by any of this.
print(math.rotl(x, 7));
print(math.rotl(x, 45));