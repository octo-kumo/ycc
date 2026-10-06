// The randomness source on both targets. std/crypto.random_bytes reaches
// y_os_random, which is getrandom(2) on Linux and RtlGenRandom
// (SystemFunction036, advapi32) on NT -- one call, no provider and no handle,
// because wine cannot be driven through BCrypt's three-call sequence (rounds
// 34-49: both the documented pseudo-handle and a real handle from a real
// BCryptOpenAlgorithmProvider page-fault inside wine's bcrypt, with the import
// table, the .bss IAT cell and the Win64 call all measured working).
//
// Everything printed here is deterministic except the bytes themselves, which
// is the point: a source that returns zeros, or the same bytes twice, fails.
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
print(len(crypto.random_bytes(0)));
