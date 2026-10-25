// X25519 with a peer whose point is of low order (RFC 7748 6.1) gave an
// all-zero shared secret and said nothing; RFC 8446 7.4.2 requires the
// handshake to abort, since a key exchange that lands on zero decides
// nothing and everything sent under it is read by whoever offered the
// point. Seven such u-coordinates, one child process each, plus the
// lengths the function takes (a longer point would be used truncated)
// and RFC 7748's own key exchange, which must still agree.
import crypto;
def show(what: str, b: [byte]) { print(what, " ", crypto.hex(b)); };
def u(s: str) -> [byte] { crypto.unhex(s) };
// the low-order points of RFC 7748 6.1, little-endian, as 32-byte hex:
// 0, 1, two more, then p-1, p and p+1 for p = 2^255 - 19
let low = ["0000000000000000000000000000000000000000000000000000000000000000",
           "0100000000000000000000000000000000000000000000000000000000000000",
           "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
           "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
           "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
           "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
           "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"];
let alice = u("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
let bob = u("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
// RFC 7748 6.1: the two public keys and the one secret both sides reach
show("alice_public", crypto.x25519_base(alice));
show("bob_public", crypto.x25519_base(bob));
show("shared", crypto.x25519(alice, crypto.x25519_base(bob)));
show("shared_back", crypto.x25519(bob, crypto.x25519_base(alice)));
foreach (pt in low) {
    let pid = fork { crypto.x25519(alice, u(pt)); print("low order not reached") };
    print("u = ", pt[0:8], "... -> ", wait_pid(pid));
};
// the scalar and the point are 32 bytes each
let pid2 = fork { crypto.x25519(alice[0:31], crypto.x25519_base(bob)); print("short scalar not reached") };
print("31-byte scalar -> ", wait_pid(pid2));
let pid3 = fork { crypto.x25519(alice, crypto.x25519_base(bob) + [0]); print("long point not reached") };
print("33-byte point -> ", wait_pid(pid3));