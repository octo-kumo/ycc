// tools/keyserver/store.y -- the deployment state files: users, the pinned
// server key, and the persistent client-nonce store.
import fs;
import crypto;

type User = { name: str, secret: [byte], license: str };

def is_space(c: long) -> bool { c == 32 || c == 9 || c == 10 || c == 13 };

// All the bytes of a file that is not empty, or none.
def read_or_none(path: str) -> [byte]? {
    let b = fs.read_bytes(path);
    if (b == none || len(b!) == 0) { none } else { b }
};

// A key file is either raw bytes or an even-length hex string; accept both so
// an operator can paste a fingerprint from `openssl` or keep a binary secret.
def key_material(path: str, need: long) -> [byte]? {
    let b = read_or_none(path);
    if (b == none) { return none; };
    let raw = b!;
    let text = true;
    let n = 0;
    while (n < len(raw) && text) {
        let c = raw[n];
        if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70))) { text = false; };
        n += 1;
    };
    let out: [byte] = [];
    if (text && len(raw) % 2 == 0 && len(raw) / 2 >= need) {
        out = crypto.unhex(from_bytes(raw));
    } else if (len(raw) >= need) {
        out = raw[0:need];
    } else {
        return none;
    };
    if (len(out) < need) { none } else { some(out) }
};

// A users file: one `user secret-hex license` record per line; `#` starts a
// comment and blank lines are ignored. Duplicate or malformed rows are errors,
// never silently skipped (a typo must not disable a customer's check).
def load_users(path: str) -> { ok: bool, err: str, users: [User] } {
    let t = fs.read_file(path);
    if (t == none) { return { ok: false, err: "cannot read users file", users: [] }; };
    let out: [User] = [];
    let bad = "";
    foreach (line in split(t!, "\n")) {
        let l = line.trim();
        if (len(l) == 0 || l[0] == '#') { continue; };
        let w = split(l, " ");
        let ws: [str] = [];
        foreach (part in w) { if (len(part) > 0) { ws += part; }; };
        if (len(ws) != 3) { bad = "users line needs user, secret and license"; continue; };
        let sec = crypto.unhex(ws[1]);
        if (len(sec) < 16) { bad = "user '" + ws[0] + "' has a short secret"; continue; };
        let dup = false;
        foreach (u in out) { if (u.name == ws[0]) { dup = true; }; };
        if (dup) { bad = "duplicate user '" + ws[0] + "'"; continue; };
        out += { name: ws[0], secret: sec, license: ws[2] };
    };
    if (bad != "") { { ok: false, err: bad, users: [] } }
    else if (len(out) == 0) { { ok: false, err: "users file has no users", users: [] } }
    else { { ok: true, err: "", users: out } }
};

def find_user(users: [User], name: str) -> User? {
    foreach (u in users) { if (u.name == name) { return some(u); }; };
    none
};

// An RSA private key file is two hex lines (comments and `n =` / `d =` labels
// allowed): the modulus and the private exponent. The public pin file is the
// modulus, optionally followed by a public exponent (default 65537).
def hex_lines(path: str) -> { ok: bool, lines: [str] } {
    let t = fs.read_file(path);
    if (t == none) { return { ok: false, lines: [] }; };
    let out: [str] = [];
    foreach (line in split(t!, "\n")) {
        let l = line.trim();
        if (len(l) == 0 || l[0] == '#') { continue; };
        let eq = l.index_of("=");
        if (eq >= 0) { l = l[eq + 1:].trim(); };
        out += l;
    };
    { ok: len(out) > 0, lines: out }
};

def load_rsa_priv(path: str) -> { ok: bool, err: str, n: [byte], d: [byte] } {
    let h = hex_lines(path);
    if (!h.ok || len(h.lines) < 2) {
        return { ok: false, err: "RSA key needs modulus and private exponent lines", n: [], d: [] };
    };
    let n = crypto.unhex(h.lines[0]);
    let d = crypto.unhex(h.lines[1]);
    if (len(n) < 256) { return { ok: false, err: "RSA modulus needs 2048 bits", n: [], d: [] }; };
    if (len(d) < 32) { return { ok: false, err: "RSA private exponent is missing", n: [], d: [] }; };
    { ok: true, err: "", n: n, d: d }
};

def load_rsa_pub(path: str) -> { ok: bool, err: str, n: [byte], e: [byte] } {
    let h = hex_lines(path);
    if (!h.ok) { return { ok: false, err: "cannot read the pin file", n: [], e: [] }; };
    let n = crypto.unhex(h.lines[0]);
    let e = crypto.unhex("010001");
    if (len(h.lines) >= 2) { e = crypto.unhex(h.lines[1]); };
    if (len(n) < 256) { return { ok: false, err: "pinned RSA modulus needs 2048 bits", n: [], e: [] }; };
    if (len(e) == 0) { return { ok: false, err: "pinned public exponent is empty", n: [], e: [] }; };
    { ok: true, err: "", n: n, e: e }
};

// A token file for the remote executor is either one raw 16+ byte token or a
// list of hex tokens (one per line, # comments allowed). A hex list lets one
// deployment hold a token per user and revoke a user by deleting a line.
def load_tokens(path: str) -> { ok: bool, err: str, tokens: [[byte]] } {
    let b = read_or_none(path);
    if (b == none) { return { ok: false, err: "cannot read the token file", tokens: [] }; };
    let raw = b!;
    let h = hex_lines(path);
    let list: [[byte]] = [];
    let all_hex = h.ok;
    if (all_hex) {
        foreach (l in h.lines) {
            let t = crypto.unhex(l);
            if (len(t) < 16) { all_hex = false; };
            list += t;
        };
    };
    if (all_hex && len(list) > 0) { return { ok: true, err: "", tokens: list }; };
    if (len(raw) < 16) { return { ok: false, err: "token file needs 16 bytes", tokens: [] }; };
    { ok: true, err: "", tokens: [raw[0:16]] }
};

// The nonce store is one 64-hex client nonce per line. It is read once at
// startup and appended after a successful auth, so a replay is refused across
// restarts, not only within one process. The file is capped: when it grows past
// `cap`, the newest `keep` half is rewritten (old nonces are older than the
// handshake timeout anyway).
def load_nonces(path: str, cap: long) -> { seen: [str], err: str } {
    let b = read_or_none(path);
    let seen: [str] = [];
    if (b == none) { return { seen: seen, err: "" }; };
    foreach (line in split(from_bytes(b!), "\n")) {
        let l = line.trim();
        // The keyserver's client nonce is 32 bytes, the remote executor's is
        // 16, so any even 32..64 hex characters is a valid stored nonce.
        if (len(l) >= 32 && len(l) <= 64 && len(l) % 2 == 0) { seen += l; };
    };
    if (len(seen) > cap) {
        let keep = seen[len(seen) - cap:len(seen)];
        let text = "";
        foreach (s in keep) { text += s + "\n"; };
        if (!fs.write_file(path, text)) { return { seen: keep, err: "cannot prune the nonce file" }; };
        return { seen: keep, err: "" };
    };
    { seen: seen, err: "" }
};

def nonce_has(seen: [str], id: str) -> bool {
    foreach (s in seen) { if (s == id) { return true; }; };
    false
};

def nonce_add(path: str, seen: [str], id: str, cap: long) -> bool {
    if (!fs.append_file(path, id + "\n")) { return false; };
    seen += id;
    if (len(seen) > cap * 2) {
        let keep = seen[len(seen) - cap:len(seen)];
        let text = "";
        foreach (s in keep) { text += s + "\n"; };
        return fs.write_file(path, text);
    };
    true
};

// A portion of memory is not secret once the key is gone.
def wipe(b: [byte]) -> void {
    for i in 0..len(b) { b[i] = 0; };
};

export { User, is_space, read_or_none, key_material, load_users, find_user,
    hex_lines, load_rsa_priv, load_rsa_pub, load_tokens, load_nonces, nonce_has, nonce_add, wipe };
