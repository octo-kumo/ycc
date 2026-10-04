// The keys and nonces the ciphers take: AES wants 16, 24 or 32 bytes and
// ChaCha20 exactly 32, and both want a 12-byte nonce. Every other length
// used to pass silently (a longer ChaCha20 key truncated, so two keys
// gave the same ciphertext; a 15-byte AES key read as 12; an 8-byte one
// run for eight rounds, which is no AES at all) or trap `index out of
// bounds` -- the checks now say which length is wanted. Each rejected
// call runs in a child process (a check stops the program), so one
// fixture covers them all. The three AES key sizes FIPS 197 has an
// answer for must keep giving it.
import crypto;
def show(what: str, b: [byte]) { print(what, " ", crypto.hex(b)); };
def u(s: str) -> [byte] { crypto.unhex(s) };
// b repeated up to exactly sz bytes, as a fresh array (a slice or a `+=`
// would share -- and grow -- the one it was handed)
def pad(b: [byte], sz: long) -> [byte] {
    let o: [byte] = [];
    let i = 0;
    while (i < sz) {
        o += b[i % len(b)];
        i = i + 1;
    };
    o
};
let k = u("aff1fe38efd51a0f6b90c5f254c2a276a30a10d31d018e480c0e14dc9aa7b6d0");
let n = u("88460834a1d40e78a83c1663");
let aad = u("508bcbbe1de9e129");
let pt = u("23f397f2c68ee01ab359");
let block = u("00112233445566778899aabbccddeeff");
// the AES key sizes FIPS 197 has a ciphertext for
show("aes128", crypto.aes_encrypt(crypto.aes_key(u("000102030405060708090a0b0c0d0e0f")), block));
show("aes192", crypto.aes_encrypt(crypto.aes_key(u("000102030405060708090a0b0c0d0e0f1011121314151617")), block));
show("aes256", crypto.aes_encrypt(crypto.aes_key(u("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")), block));
show("chacha", crypto.chacha_seal(k, n, aad, pt));
foreach (sz in [16, 31, 40, 64]) {
    let bad = pad(k, sz);
    let pid = fork { crypto.chacha_seal(bad, n, aad, pt); print("chacha key not reached") };
    print("chacha key ", sz, " -> ", wait_pid(pid));
};
foreach (sz in [0, 4, 8, 13, 16]) {
    let bad = pad(n, sz);
    let pid = fork { crypto.chacha_seal(k, bad, aad, pt); print("chacha nonce not reached") };
    print("chacha nonce ", sz, " -> ", wait_pid(pid));
};
foreach (sz in [0, 8, 15, 20, 31, 33, 64]) {
    let bad = pad(k, sz);
    let pid = fork { crypto.aes_encrypt(crypto.aes_key(bad), block); print("aes key not reached") };
    print("aes key ", sz, " -> ", wait_pid(pid));
};
// the same key rule reaches GCM and the raw stream cipher
let pid = fork { crypto.gcm_seal(pad(k, 15), n, aad, pt); print("gcm key not reached") };
print("gcm key 15 -> ", wait_pid(pid));
let pid2 = fork { crypto.chacha20(pad(k, 40), 1, n, pt); print("chacha20 not reached") };
print("chacha20 key 40 -> ", wait_pid(pid2));