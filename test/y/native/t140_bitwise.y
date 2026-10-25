// The bitwise operators: & | ^ ~ on integers (a byte widens, the result
// is a long), << and the two right shifts, >> (arithmetic: the sign fills
// in) and >>> (logical: zeros fill in), and their compound forms.
print(12 & 10);                     // 8
print(12 | 10);                     // 14
print(12 ^ 10);                     // 6
print(~0);                          // -1
print(~5);                          // -6
print(~~7);                         // 7
print(-~5);                         // 6
print(1 << 10);                     // 1024
print(1024 >> 3);                   // 128
print(1024 >>> 3);                  // 128
print(-16 >> 2);                    // -4
print(-16 >>> 60);                  // 15
print(-1 >>> 1);                    // 9223372036854775807
print(1 << 63);                     // -9223372036854775808
print(-1 ^ 0x7FFF_FFFF_FFFF_FFFF);  // -9223372036854775808
print(0xDEAD_BEEF & 0xFFFF);        // 48879
print(0xDEAD_BEEF >> 16);           // 57005
print(0b1010 | 0b0101);             // 15
print(0xFFFF_FFFF_FFFF_FFFF);       // -1 (a radix literal is its 64 bits)
print(0x8000_0000_0000_0000 >>> 63);  // 1

// precedence: below + - * / %, above the comparisons (unlike C), and
// & before ^ before |
print(6 & 3 == 2);                  // true ((6 & 3) == 2)
print(1 | 2 ^ 3 & 4);               // 3
print(1 << 2 + 3);                  // 32
print(1 + 2 << 3);                  // 24
print(2 * 3 & 4);                   // 4
print(1 << 4 & 0xF0);               // 16
print(1 << 3 > 7);                  // true
print(5 & 4 != 0 && 2 | 1 == 3);    // true
let xs = [9];
print(1 | 2 :: xs);                 // [3, 9] (:: is looser still)
print(~xs[0]);                      // -10 (postfix first)

// the count: 64 or more shifts every bit out (0, or the sign for >>); a
// literal 0 to 63 is an immediate
let n = 3;
print(1 << n);                      // 8
let big = 64;
print(7 << big);                    // 0
print(7 >> big);                    // 0
print(-7 >> big);                   // -1
print(7 >>> big);                   // 0
print(-7 >>> big);                  // 0
let huge = 1000;
print(-7 >> huge);                  // -1
print(1 << 64);                     // 0
print(-1 >> 64);                    // -1
print(-1 >>> 64);                   // 0
print(5 << 0);                      // 5
print(3 << 63);                     // -9223372036854775808
print(1 << 0x10);                   // 65536
let n63 = 63;
print(1 << n63);                    // -9223372036854775808
print(-8 >> n63);                   // -1
print(8 >> n63);                    // 0
let zero = 0;
print(-5 >> zero);                  // -5

// the left operand first, then the right, each once
let trace = "";
def lhs() -> long { trace += "l"; 1 };
def rhs() -> long { trace += "r"; 4 };
print(lhs() << rhs());              // 16
print(lhs() & rhs());               // 0
print(trace);                       // lrlr

// bytes widen: the result is a long, never cut to 8 bits
let b1: byte = 0xF0;
let b2: byte = 0x3C;
print(b1 & b2);                     // 48
print(b1 | b2);                     // 252
print(b1 ^ b2);                     // 204
print(b1 << 4);                     // 3840
print(b1 >> 4);                     // 15
print(~b1);                         // -241
print(typeof(b1 & b2));             // long
let nb: byte = ~b1;
print(nb);                          // 15 (a byte store keeps the low 8 bits)

// compound forms on every place: a variable, a byte, an element, a field
let x = 0b1100;
x &= 0b1010;
print(x);                           // 8
x |= 3;
print(x);                           // 11
x ^= 0xF;
print(x);                           // 4
x <<= 4;
print(x);                           // 64
x >>= 2;
print(x);                           // 16
x = -1;
x >>>= 60;
print(x);                           // 15
let v = { x ^= 5 };
print(v);                           // 10 (the value stored)
let by: byte = 0xF0;
by |= 0x10F;
print(by);                          // 255 (the low 8 bits of 0x1FF)
by <<= 4;
print(by);                          // 240
by ^= by;
print(by);                          // 0
let arr = [1, 2, 3];
let calls = 0;
def bump() -> long { calls += 1; calls };
arr[bump()] |= 8;
print(arr);                         // [1, 10, 3]
print(calls);                       // 1 (the index is evaluated once)
let bs: [byte] = [0x0F, 0xF0];
bs[0] <<= 5;
bs[1] >>= 4;
print(bs[0]);                       // 224 (0x1E0, packed: 0xE0)
print(bs[1]);                       // 15
let rec = { flags: 0 };
rec.flags |= 1 << 2;
rec.flags |= 1 << 5;
rec.flags &= ~(1 << 2);
print(rec.flags);                   // 32

// a global from a function, and a captured variable
let mask = 0;
def setbit(b: long) { mask |= 1 << b; };
setbit(0);
setbit(3);
print(mask);                        // 9
def collect() -> long {
    let m = 0;
    let set = def(b: long) { m |= 1 << b; };
    set(1);
    set(4);
    m
};
print(collect());                   // 18

// conditions still take a bool: test a bit with != 0
let flags = 0b101;
if (flags & 4 != 0) { print("bit 2"); };
if (flags & 2 == 0) { print("no bit 1"); };

// two everyday uses: counting bits and a hash (FNV-1a, 64 bits)
def popcount(w: long) -> long {
    let c = 0;
    while (w != 0) {
        c += w & 1;
        w >>>= 1;
    };
    c
};
print(popcount(0));                 // 0
print(popcount(0xF0F0));            // 8
print(popcount(-1));                // 64
def fnv1a(s: str) -> long {
    let h = 0xcbf2_9ce4_8422_2325;
    for i in 0..len(s) {
        h ^= byte_at(s, i);
        h *= 0x100_0000_01b3;
    };
    h
};
print(fnv1a(""));                   // -3750763034362895579
print(fnv1a("a"));                  // -5808556873153909620
print(fnv1a("hello"));              // -6615550055289275125

// maximal munch: no spaces needed
let m = -1;
m>>>=60;
print(m);                           // 15
print(m<<2|1);                      // 61
print(m>>1^m&3);                    // 4 ((m >> 1) ^ (m & 3))
print(~m&0xFF);                     // 240
m<<=1;
print(m);                           // 30
