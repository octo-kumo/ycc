// A GCM nonce is 12 bytes (SP 800-38D): the 12-byte one still seals to
// the known answer, and any other length is a caller's mistake, named --
// a longer nonce needs the GHASH-built J0 of SP 800-38D 7.1 that this
// module does not build, and sealing with the wrong J0 made two nonces
// sharing their first 16 bytes a nonce reuse in all but name (the same
// ciphertext *and* the same tag). Each rejected call runs in a child
// process (the check stops the program), so one fixture covers them all.
import crypto;
def u(s: str) -> [byte] { crypto.unhex(s) };
let head = u("73329c9e62626c327ad7a008");
// the 12 bytes of a nonce, then the head repeated to whatever length
def nonce_of(n: long) -> [byte] {
    let b: [byte] = [];
    let i = 0;
    while (i < n) {
        b += head[i % 12];
        i = i + 1;
    };
    b
};
let key = u("15e3db6cf395c3025e3d1c4b2cbb77fd");
let n12 = nonce_of(12);
let plain = u("5decba59cc58c88af346d1186b5a0cf1");
print(crypto.hex(crypto.gcm_seal(key, n12, bytes(""), plain))[0:32], "...");
foreach (n in [4, 17, 32, 60]) {
    let bad = nonce_of(n);
    let pid = fork { crypto.gcm_seal(key, bad, bytes(""), plain); print("seal not reached") };
    print(n, " bytes -> ", wait_pid(pid));
};
// ... and open is checked the same way (it shares the counter block)
let sealed = crypto.gcm_seal(key, n12, bytes(""), plain);
let pid = fork { crypto.gcm_open(key, n12 + [0], bytes(""), sealed); print("open not reached") };
print("open, 13 bytes -> ", wait_pid(pid));
// a 12-byte nonce and a 16-byte key round-trip unchanged
print(crypto.hex(crypto.gcm_open(key, n12, bytes(""), sealed)!));