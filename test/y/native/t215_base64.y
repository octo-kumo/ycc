// base64 (RFC 4648) in std/struct.y: the encoder the tree had no copy of,
// beside the decoder that lived in std/x509.y for PEM's sake. The RFC 4648
// test vectors are the point of the first block: "" -> "", "f" -> "Zg==",
// "fo" -> "Zm8=", "foo" -> "Zm9v", "foob" -> "Zm9vYg==", "fooba" ->
// "Zm9vYmE=", "foobar" -> "Zm9vYmFy".
import struct;

// the RFC's own vectors
print(struct.b64_encode(b""), "|", struct.b64_encode(b"f"), "|", struct.b64_encode(b"fo"));
print(struct.b64_encode(b"foo"), "|", struct.b64_encode(b"foob"), "|", struct.b64_encode(b"fooba"));
print(struct.b64_encode(b"foobar"), "|", struct.b64_encode(b"f"), "|", struct.b64_encode(b"fo"));

// every length round-trips, padding and all: 0..8 covers all three remainders
let n = 0;
while (n < 9) {
    let b: [byte] = [];
    let i = 0;
    while (i < n) { b += (i * 37 + 11) % 256; i = i + 1; };
    let text = struct.b64_encode(b);
    let back = struct.b64_decode(text);
    let same = (len(back) == n);
    let j = 0;
    while (same && j < n) {
        if (back[j] != b[j]) { same = false; };
        j = j + 1;
    };
    print(n, " -> [", text, "] -> ", same, " (", len(text), " chars, ",
          len(text) % 4, " mod 4)");
    n = n + 1;
};

// the alphabet's ends, which are the ones a hand-rolled table gets wrong
print(struct.b64_encode(b"\xff\xfe\xfd"), "|", struct.b64_encode(b"\x00\x00\x00"));
print(struct.b64_decode("///"), "|", struct.b64_decode("++++"), "|", struct.b64_decode("AAAB"));

// a decoder skips what is not in the alphabet and stops at "=", which is what
// a PEM block needs
print(struct.b64_decode("Zm9v YmFy"), "|", struct.b64_decode("Zm9vYmFy=="), "|", struct.b64_decode("!!!Zm9vYmFy"));
print(struct.b64_decode(""), "|", struct.b64_decode("="), "|", struct.b64_decode("Z"));

// x509 keeps its name for the same function, so PEM still works
import x509;
let pem = "-----BEGIN CERTIFICATE-----\nZm9vYmFy\n-----END CERTIFICATE-----\n";
print(x509.pem_certs(pem), "|", x509.b64_decode("Zm9vYmFy"));