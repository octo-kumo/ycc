// random_bytes through the named layer, on both targets. On NT the source is
// BCryptGenRandom (a DLL export, so it arrives as an import the PE writer
// emits and the loader resolves into a .bss cell the code calls through);
// on Linux it is getrandom(2). Neither is deterministic, so this asserts the
// PROPERTIES -- the length, that the bytes are not all zero, and that two
// draws differ -- which makes the output the same on both targets and lets
// pe-fixtures.sh hold the NT path to something. (t158_crypto.y cannot: its own
// output depends on the random bytes.)
import crypto;
let a = crypto.random_bytes(16);
let b = crypto.random_bytes(16);
print(len(a));
let z = 0;
let i = 0;
while (i < 16) { z = z | a[i]; i = i + 1; };
print(z != 0);
print(crypto.bytes_eq(a, b));
print(crypto.bytes_eq(a, a));
