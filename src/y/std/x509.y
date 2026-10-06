// std/x509.y — X.509 certificates (RFC 5280) as a TLS client needs them:
// DER, PEM bundles, the system's trust anchors, and the verification of a
// server's chain for a host name.
//
//     import x509;
//     let why = x509.verify_chain(chain, "example.com", time_us() / 1000000);
//     // "" when the chain is good; else what is wrong with it
//
// A chain is the DER of the server's certificates, its own first. It is
// good when some path leads from that certificate to a trust anchor
// (the system bundle, or anchors of the caller's), each certificate
// signed by the next (RSA PKCS #1 v1.5 or ECDSA on P-256/P-384, SHA-2),
// each in its validity period, each issuer a CA; and the first one names
// the host (its subjectAltName DNS names, `*.` matching one label).
// Not checked: revocation, name constraints, policies, key usage.
import crypto;
import fs;

// ── DER (X.690) ──────────────────────────────────────────────────────────

// An element of b: its tag byte, where it starts, where its contents start
// (at) and end (end); tag -1 for one that is malformed.
type Tlv = { tag: long, start: long, at: long, end: long };

def tlv(b: [byte], p: long, limit: long) -> Tlv {
    let bad: Tlv = { tag: -1, start: p, at: p, end: p };
    if (p < 0 || p + 2 > limit) { return bad; };
    let tag: long = b[p];
    let l: long = b[p + 1];
    let at = p + 2;
    if (l >= 128) {
        let n = l & 127;
        if (n == 0 || n > 4 || at + n > limit) { return bad; };
        l = 0;
        let i = 0;
        while (i < n) {
            l = (l << 8) | b[at + i];
            i = i + 1;
        };
        at = at + n;
    };
    if (at + l > limit) { return bad; };
    { tag: tag, start: p, at: at, end: at + l }
};

// The elements inside constructed element e (a malformed one ends them).
def kids(b: [byte], e: Tlv) -> [Tlv] {
    let out: [Tlv] = [];
    let p = e.at;
    while (p < e.end) {
        let k = tlv(b, p, e.end);
        if (k.tag < 0) { return out; };
        out += k;
        p = k.end;
    };
    out
};

def content(b: [byte], e: Tlv) -> [byte] { b[e.at:e.end] };
def element(b: [byte], e: Tlv) -> [byte] { b[e.start:e.end] };

// ── base64 and PEM ───────────────────────────────────────────────────────

def b64_value(c: byte) -> long {
    if (c >= 'A' && c <= 'Z') { c - 'A' }
    else if (c >= 'a' && c <= 'z') { c - 'a' + 26 }
    else if (c >= '0' && c <= '9') { c - '0' + 52 }
    else if (c == '+') { 62 }
    else if (c == '/') { 63 }
    else { -1 }
};

// The bytes base64 text s encodes (other characters are skipped; `=`
// ends it).
def b64_decode(s: str) -> [byte] {
    let out: [byte] = [];
    let acc = 0;
    let bits = 0;
    let i = 0;
    while (i < len(s) && s[i] != '=') {
        let v = b64_value(s[i]);
        if (v >= 0) {
            acc = ((acc << 6) | v) & 0xffffff;
            bits = bits + 6;
            if (bits >= 8) {
                bits = bits - 8;
                out += (acc >> bits) & 255;
            };
        };
        i = i + 1;
    };
    out
};

// The DER of every CERTIFICATE block in PEM text.
def pem_certs(text: str) -> [[byte]] {
    let out: [[byte]] = [];
    let begin = "-----BEGIN CERTIFICATE-----";
    let end = "-----END CERTIFICATE-----";
    let p = index_of(text, begin);
    while (p >= 0) {
        let rest = text[p + len(begin):len(text)];
        let q = index_of(rest, end);
        if (q < 0) { return out; };
        out += [b64_decode(rest[0:q])];
        let after = rest[q + len(end):len(rest)];
        text = after;
        p = index_of(text, begin);
    };
    out
};

// ── time ─────────────────────────────────────────────────────────────────

// Days from 1970-01-01 to y-m-d (proleptic Gregorian; Howard Hinnant's
// days_from_civil).
def days_from_civil(y0: long, m: long, d: long) -> long {
    let y = y0;
    if (m <= 2) { y = y - 1; };
    let era = y / 400;
    if (y < 0) { era = (y - 399) / 400; };
    let yoe = y - era * 400;
    let mp = m + 9;
    if (m > 2) { mp = m - 3; };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
};

def digits(b: [byte], p: long, n: long) -> long {
    let v = 0;
    let i = 0;
    while (i < n) {
        let c = b[p + i];
        if (c < '0' || c > '9') { return -1; };
        v = v * 10 + (c - '0');
        i = i + 1;
    };
    v
};

// A UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ) as Unix
// seconds; -1 for another form.
def asn1_time(b: [byte], e: Tlv) -> long {
    let p = e.at;
    let n = e.end - e.at;
    let y = -1;
    if (e.tag == 0x17 && n == 13) {
        y = digits(b, p, 2);
        if (y >= 0) {
            if (y < 50) { y = y + 2000; } else { y = y + 1900; };
        };
        p = p + 2;
    } else if (e.tag == 0x18 && n == 15) {
        y = digits(b, p, 4);
        p = p + 4;
    };
    if (y < 0 || b[e.end - 1] != 'Z') { return -1; };
    let mo = digits(b, p, 2);
    let d = digits(b, p + 2, 2);
    let h = digits(b, p + 4, 2);
    let mi = digits(b, p + 6, 2);
    let s = digits(b, p + 8, 2);
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h < 0 || mi < 0 || s < 0) { return -1; };
    days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
};

// ── certificates ─────────────────────────────────────────────────────────

// What verification reads of a certificate. The algorithms are the hex of
// their OIDs; `key` is an RSAPublicKey's DER or an EC point (04 x y).
type Cert = {
    ok: bool, der: [byte], tbs: [byte], sig_alg: str, sig: [byte],
    issuer: [byte], subject: [byte], not_before: long, not_after: long,
    key_alg: str, key_curve: str, key: [byte], is_ca: bool, dns: [str],
    ips: [[byte]]
};

let OID_RSA = "2a864886f70d010101";
let OID_EC = "2a8648ce3d0201";
let OID_P256 = "2a8648ce3d030107";
let OID_P384 = "2b81040022";

def bad_cert(der: [byte]) -> Cert {
    {
        ok: false, der: der, tbs: [], sig_alg: "", sig: [], issuer: [], subject: [],
        not_before: 0, not_after: -1, key_alg: "", key_curve: "", key: [], is_ca: false, dns: [],
        ips: []
    }
};

// The certificate whose DER is b; ok false when it is malformed.
def parse_cert(b: [byte]) -> Cert {
    let top = tlv(b, 0, len(b));
    if (top.tag != 0x30) { return bad_cert(b); };
    let parts = kids(b, top);
    if (len(parts) != 3 || parts[0].tag != 0x30 || parts[1].tag != 0x30 || parts[2].tag != 0x03) { return bad_cert(b); };
    let sa = kids(b, parts[1]);
    let sigbits = content(b, parts[2]);
    if (len(sa) < 1 || sa[0].tag != 0x06 || len(sigbits) < 1 || sigbits[0] != 0) { return bad_cert(b); };
    let t = kids(b, parts[0]);
    let i = 0;
    if (len(t) > 0 && t[0].tag == 0xa0) { i = 1; };
    if (len(t) < i + 6) { return bad_cert(b); };
    let validity = kids(b, t[i + 3]);
    if (len(validity) != 2) { return bad_cert(b); };
    let spki = kids(b, t[i + 5]);
    if (len(spki) != 2 || spki[1].tag != 0x03) { return bad_cert(b); };
    let ka = kids(b, spki[0]);
    if (len(ka) < 1 || ka[0].tag != 0x06) { return bad_cert(b); };
    let curve = "";
    if (len(ka) > 1 && ka[1].tag == 0x06) { curve = crypto.hex(content(b, ka[1])); };
    let keybits = content(b, spki[1]);
    if (len(keybits) < 1) { return bad_cert(b); };
    let is_ca = false;
    let dns: [str] = [];
    let ips: [[byte]] = [];
    let j = i + 6;
    while (j < len(t)) {
        if (t[j].tag == 0xa3) {
            let exts = kids(b, t[j]);
            if (len(exts) == 1 && exts[0].tag == 0x30) {
                foreach (ext in kids(b, exts[0])) {
                    let ek = kids(b, ext);
                    if (len(ek) >= 2 && ek[0].tag == 0x06) {
                        let id = crypto.hex(content(b, ek[0]));
                        let val = ek[len(ek) - 1];
                        if (val.tag == 0x04) {
                            let inner = tlv(b, val.at, val.end);
                            if (id == "551d13" && inner.tag == 0x30) {
                                let bc = kids(b, inner);
                                if (len(bc) > 0 && bc[0].tag == 0x01 && bc[0].end > bc[0].at && b[bc[0].at] != 0) { is_ca = true; };
                            } else if (id == "551d11" && inner.tag == 0x30) {
                                foreach (gn in kids(b, inner)) {
                                    if (gn.tag == 0x82) { dns += from_bytes(content(b, gn)); }
                                    // GeneralName 7 is iPAddress: 4 bytes for
                                    // IPv4, 16 for IPv6 (RFC 5280 4.2.1.6).
                                    else if (gn.tag == 0x87) { ips += content(b, gn); };
                                };
                            };
                        };
                    };
                };
            };
        };
        j = j + 1;
    };
    {
        ok: true, der: b, tbs: element(b, parts[0]), sig_alg: crypto.hex(content(b, sa[0])),
        sig: sigbits[1:len(sigbits)], issuer: element(b, t[i + 2]), subject: element(b, t[i + 4]),
        not_before: asn1_time(b, validity[0]), not_after: asn1_time(b, validity[1]),
        key_alg: crypto.hex(content(b, ka[0])), key_curve: curve, key: keybits[1:len(keybits)],
        is_ca: is_ca, dns: dns, ips: ips
    }
};

// ── signatures ───────────────────────────────────────────────────────────

// The hash a signature algorithm (OID hex) uses: its digest of data, or
// [] for an algorithm not supported (SHA-1 among them).
def alg_digest(alg: str, data: [byte]) -> [byte] {
    let none_d: [byte] = [];
    if (alg == "2a864886f70d01010b" || alg == "2a8648ce3d040302") { crypto.sha256(data) }
    else if (alg == "2a864886f70d01010c" || alg == "2a8648ce3d040303") { crypto.sha384(data) }
    else if (alg == "2a864886f70d01010d" || alg == "2a8648ce3d040304") { crypto.sha512(data) }
    else { none_d }
};

// An RSAPublicKey's modulus and exponent ([] each when malformed).
def rsa_key(k: [byte]) -> [[byte]] {
    let out: [[byte]] = [];
    let top = tlv(k, 0, len(k));
    if (top.tag != 0x30) { return out; };
    let ne = kids(k, top);
    if (len(ne) != 2 || ne[0].tag != 0x02 || ne[1].tag != 0x02) { return out; };
    out += [content(k, ne[0])];
    out += [content(k, ne[1])];
    out
};

// An ECDSA signature's DER (SEQUENCE { r INTEGER, s INTEGER }) as r, s.
def ecdsa_rs(sig: [byte]) -> [[byte]] {
    let out: [[byte]] = [];
    let top = tlv(sig, 0, len(sig));
    if (top.tag != 0x30) { return out; };
    let rs = kids(sig, top);
    if (len(rs) != 2 || rs[0].tag != 0x02 || rs[1].tag != 0x02) { return out; };
    out += [content(sig, rs[0])];
    out += [content(sig, rs[1])];
    out
};

// sig is a good signature of digest by key holder c: RSA PKCS #1 v1.5
// (pss false) or PSS (pss true, MGF1 and salt from the digest's hash),
// or ECDSA (sig in DER) on the curve of c's key.
def key_verifies(c: Cert, digest: [byte], sig: [byte], pss: bool) -> bool {
    if (len(digest) == 0) { return false; };
    if (c.key_alg == OID_RSA) {
        let ne = rsa_key(c.key);
        if (len(ne) != 2) { return false; };
        if (pss) {
            let h = crypto.hash_sha256();
            if (len(digest) == 48) { h = crypto.hash_sha384(); };
            crypto.rsa_verify_pss(ne[0], ne[1], h, digest, sig)
        } else {
            crypto.rsa_verify_pkcs1(ne[0], ne[1], digest, sig)
        }
    } else if (c.key_alg == OID_EC && !pss) {
        let rs = ecdsa_rs(sig);
        if (len(rs) != 2 || len(c.key) < 1 || c.key[0] != 4) { return false; };
        let n = (len(c.key) - 1) / 2;
        let qx = c.key[1:1 + n];
        let qy = c.key[1 + n:len(c.key)];
        if (c.key_curve == OID_P256 && n == 32) { crypto.ecdsa_verify(crypto.p256(), qx, qy, digest, rs[0], rs[1]) }
        else if (c.key_curve == OID_P384 && n == 48) { crypto.ecdsa_verify(crypto.p384(), qx, qy, digest, rs[0], rs[1]) }
        else { false }
    } else { false }
};

// Certificate c is signed by the holder of `by`'s key.
def signed_by(c: Cert, by: Cert) -> bool {
    let alg = c.sig_alg;
    let ec = alg == "2a8648ce3d040302" || alg == "2a8648ce3d040303" || alg == "2a8648ce3d040304";
    if (ec != (by.key_alg == OID_EC)) { return false; };
    key_verifies(by, alg_digest(alg, c.tbs), c.sig, false)
};

// A TLS 1.3 CertificateVerify signature (RFC 8446 4.2.3) of data by the
// key of the certificate whose DER is leaf: scheme rsa_pss_rsae_sha256
// (0x0804) or _sha384 (0x0805), ecdsa_secp256r1_sha256 (0x0403) or
// ecdsa_secp384r1_sha384 (0x0503).
def verify_signed(leaf: [byte], scheme: long, data: [byte], sig: [byte]) -> bool {
    let c = parse_cert(leaf);
    if (!c.ok) { false }
    else if (scheme == 0x0804) { c.key_alg == OID_RSA && key_verifies(c, crypto.sha256(data), sig, true) }
    else if (scheme == 0x0805) { c.key_alg == OID_RSA && key_verifies(c, crypto.sha384(data), sig, true) }
    else if (scheme == 0x0403) { c.key_curve == OID_P256 && key_verifies(c, crypto.sha256(data), sig, false) }
    else if (scheme == 0x0503) { c.key_curve == OID_P384 && key_verifies(c, crypto.sha384(data), sig, false) }
    else { false }
};

// ── trust anchors ────────────────────────────────────────────────────────

let roots: [Cert] = [];
let roots_read = false;

// The system's trust anchors: the first CA bundle found, read once.
def system_roots() -> [Cert] {
    if (!roots_read) {
        roots_read = true;
        let paths = ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
                     "/etc/ssl/ca-bundle.pem", "/etc/ssl/cert.pem", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"];
        foreach (p in paths) {
            if (len(roots) == 0) {
                let text = fs.read_file(p);
                if (text != none) { roots = anchors_pem(text!); };
            };
        };
    };
    roots
};

// The certificates of a PEM text, as trust anchors.
def anchors_pem(text: str) -> [Cert] {
    let out: [Cert] = [];
    foreach (der in pem_certs(text)) {
        let c = parse_cert(der);
        if (c.ok) { out += c; };
    };
    out
};

// ── chains and names ─────────────────────────────────────────────────────

def in_period(c: Cert, now: long) -> bool { c.not_before <= now && now <= c.not_after };

// host matches a certificate's DNS name: equal but for case, or one label
// in place of a leading `*`.
def name_matches(pattern: str, host: str) -> bool {
    let p = pattern.lower();
    let h = host.lower();
    if (p == h) { return true; };
    if (len(p) > 2 && p[0] == '*' && p[1] == '.') {
        let rest = p[1:len(p)];
        let cut = len(h) - len(rest);
        cut > 0 && h[cut:len(h)] == rest && index_of(h[0:cut], ".") < 0
    } else { false }
};

// The four bytes of a dotted-quad host, or none when host is not one. Only the
// canonical decimal form is accepted (four parts, 0..255, no leading zero, no
// spaces), because a host string that is not an address must never accidentally
// compare equal to a SAN's bytes.
def ipv4_bytes(host: str) -> [byte]? {
    let n = len(host);
    let out: [byte] = [];
    let v = 0;
    let digits = 0;
    let i = 0;
    let ok = true;
    while (i < n) {
        let c = host[i];
        if (c == 46) {
            if (digits == 0) { ok = false; } else { out += v; };
            v = 0;
            digits = 0;
        } else if (c >= 48 && c <= 57) {
            if (digits == 1 && v == 0) { ok = false; };
            v = v * 10 + (c - 48);
            digits = digits + 1;
            if (v > 255 || digits > 3) { ok = false; };
        } else {
            ok = false;
        };
        if (ok) { i = i + 1; } else { i = n; };
    };
    if (!ok || digits == 0 || len(out) != 3) { none } else { out += v; some(out) }
};

def names_host(c: Cert, host: str) -> bool {
    let ok = false;
    foreach (d in c.dns) {
        if (name_matches(d, host)) { ok = true; };
    };
    // An iPAddress SAN names an IP literal, and a certificate that serves one
    // says so there rather than in a dNSName. This check used to read only
    // c.dns, so a certificate with `IP:127.0.0.1` alone was refused while the
    // same certificate with `DNS:127.0.0.1` added was accepted -- and OpenSSL's
    // s_client verifies the same certificate (SUGGESTIONS.md 14, whose
    // reproduction is now a fixture). Only IPv4 literals are matched here; a
    // 16-byte (IPv6) SAN is left for whoever adds an IPv6 host parser.
    if (!ok) {
        let want = ipv4_bytes(host);
        if (want != none) {
            foreach (a in c.ips) {
                if (len(a) == 4 && crypto.bytes_eq(a, want!)) { ok = true; };
            };
        };
    };
    ok
};

// "" when cur leads to a trust anchor through pool: an anchor or a CA of
// pool that is cur's issuer, in its period and with a good signature on
// cur, then on from there (depth: certificates so far).
def path_from(cur: Cert, pool: [Cert], anchors: [Cert], now: long, depth: long) -> str {
    foreach (a in anchors) {
        if (crypto.bytes_eq(a.subject, cur.issuer) && in_period(a, now) && signed_by(cur, a)) { return ""; };
    };
    if (depth >= 8) { return "the chain is too long"; };
    foreach (c in pool) {
        if (c.is_ca && crypto.bytes_eq(c.subject, cur.issuer) && !crypto.bytes_eq(c.der, cur.der) && in_period(c, now) && signed_by(cur, c)) {
            if (path_from(c, pool, anchors, now, depth + 1) == "") { return ""; };
        };
    };
    "certificate signed by an unknown authority"
};

// "" when chain (DER, the server's certificate first) is good for host at
// time now (Unix seconds) with these trust anchors; else why it is not.
def verify_chain_with(chain: [[byte]], host: str, now: long, anchors: [Cert]) -> str {
    if (len(chain) == 0) { return "no certificate"; };
    let leaf = parse_cert(chain[0]);
    if (!leaf.ok) { return "malformed certificate"; };
    if (!in_period(leaf, now)) { return "certificate has expired or is not yet valid"; };
    if (!names_host(leaf, host)) { return "certificate is not valid for " + host; };
    foreach (a in anchors) {
        if (crypto.bytes_eq(a.der, leaf.der)) { return ""; };
    };
    let pool: [Cert] = [];
    let i = 1;
    while (i < len(chain)) {
        let c = parse_cert(chain[i]);
        if (c.ok) { pool += c; };
        i = i + 1;
    };
    path_from(leaf, pool, anchors, now, 1)
};

// verify_chain_with the system's trust anchors.
def verify_chain(chain: [[byte]], host: str, now: long) -> str {
    verify_chain_with(chain, host, now, system_roots())
};

export { parse_cert, pem_certs, b64_decode, verify_chain, verify_chain_with, anchors_pem, system_roots, verify_signed, name_matches, days_from_civil };
