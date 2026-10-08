// pack.y -- `ytest pack-stats PACK`: attribute a std pack's bytes to its units
// and fields, and fail unless every unit's fields are consumed exactly.
//
// PACK is what `ycc --std-pack FILE` writes: the pack, an 8-digit decimal
// length and "YCCPACK1" (ycc.y write_std_pack). The pack is native.y std_pack's
// netstring frame:
//
//     "ycc-std-pack N\n"     the version line, a literal
//     count:...              how many units
//     per unit: name:...     then fields:..., stored on its own from pack 9
//                            (method byte 1 = compressed; from pack 11, 2 = compressed
//                            with the decoded length in four bytes after it)
//
// Inside, in order (native.y pack_unit_fields): files (strs), iface (count, then
// name/label/tcode each, then count, then name and strs per default), init (one
// netstring), bodies (strs), btext (strss), labels (strs), rodata (count of
// strs), globals (strs) and, from pack 8, tys (strs). pack_strs writes its count
// as its OWN netstring and does not wrap the run: reading a run as one
// netstring leaves the cursor inside it, and every later field reads garbage.
// From pack 10 the frame ends with the arch runtime's block sets (`arch.<set>`):
// a count, then per block "r" and an index into arch.linux, or "b" and the
// block (name, falls, refs strs, items, raw lines strs).
//
// The decoder is an independent implementation of native.y's lz format, so a
// reader that agrees with this one on the real pack is not agreeing with itself.
import fs;
import yt;

// The walk's cursor and the first error, shared by the readers below.
let P = 0;
let BAD = "";

def bad(msg: str) {
    if (BAD == "") { BAD = msg; };
};

def lz_decode(b: [byte]) -> [byte] {
    let out: [byte] = [];
    let at = 0;
    let n = b.length;
    while (at < n && BAD == "") {
        let t = b[at];
        at += 1;
        let ll = t >> 4;
        let mh = t & 15;
        if (ll == 15) {
            let go = true;
            while (go) {
                if (at >= n) { bad("truncated literal length"); return out; };
                let x = b[at];
                at += 1;
                ll += x;
                go = x == 255;
            };
        };
        if (at + ll > n) { bad("literals past end"); return out; };
        out += b[at:at + ll];
        at += ll;
        if (at >= n) { return out; };
        if (at + 2 > n) { bad("truncated match offset"); return out; };
        let moff = b[at] + b[at + 1] * 256;
        at += 2;
        let mlen = mh + 4;
        if (mh == 15) {
            let go = true;
            while (go) {
                if (at >= n) { bad("truncated match length"); return out; };
                let x = b[at];
                at += 1;
                mlen += x;
                go = x == 255;
            };
        };
        if (moff == 0 || moff > out.length) { bad("match offset " + tostring(moff)); return out; };
        for i in 0..mlen {
            out += out[out.length - moff];
        };
    };
    out
};

def is_digits(b: [byte]) -> bool {
    if (b.length == 0) { return false; };
    foreach (c in b) {
        if (c < 48 || c > 57) { return false; };
    };
    true
};

def dec(b: [byte]) -> long {
    let v = 0;
    foreach (c in b) { v = v * 10 + (c - 48); };
    v
};

// One netstring "LEN:TEXT" at P; P moves past it.
def nstr(s: [byte]) -> [byte] {
    if (BAD != "") { return []; };
    let q = P;
    while (q < s.length && s[q] != 58) { q += 1; };
    if (q >= s.length) { bad("no ':' at " + tostring(P)); return []; };
    let head = s[P:q];
    if (!is_digits(head)) { bad("length at " + tostring(P) + " is not decimal"); return []; };
    let n = dec(head);
    let start = q + 1;
    if (start + n > s.length) {
        bad("netstring at " + tostring(P) + " wants " + tostring(n) + " bytes, " + tostring(s.length - start) + " left");
        return [];
    };
    P = start + n;
    s[start:start + n]
};

def num(s: [byte], what: str) -> long {
    let t = nstr(s);
    if (BAD != "") { return 0; };
    if (!is_digits(t)) { bad(what + ": count is not decimal"); return 0; };
    dec(t)
};

// pack_strs (`nested` false) or pack_strss (true): a count, then the items.
def run(s: [byte], nested: bool) {
    let n = num(s, "run");
    for i in 0..n {
        if (nested) { run(s, false); } else { nstr(s); };
    };
};

def iface(s: [byte]) {
    let n = num(s, "iface exports");
    for i in 0..n {
        nstr(s);
        nstr(s);
        nstr(s);
    };
    n = num(s, "iface defaults");
    for i in 0..n {
        nstr(s);
        run(s, false);
    };
};

// Each field's byte count, walking pack_unit_fields from P = 0.
def parse_fields(body: [byte], fields: [str]) -> [long] {
    P = 0;
    let got: [long] = [];
    foreach (f in fields) {
        let start = P;
        if (f == "init") { nstr(body); }
        else if (f == "iface") { iface(body); }
        else if (f == "btext" || f == "rodata") { run(body, true); }
        else { run(body, false); };
        got += P - start;
    };
    got
};

// One arch block set: "blocks N (S shared)  items I  text T", consumed exactly.
def arch_set(body: [byte]) -> str {
    P = 0;
    let n = num(body, "arch blocks");
    let shared = 0;
    let irb = 0;
    let txtb = 0;
    for i in 0..n {
        let tag = from_bytes(nstr(body));
        if (tag == "r") {
            num(body, "arch shared index");
            shared += 1;
        } else if (tag == "b") {
            nstr(body);
            nstr(body);
            run(body, false);
            irb += nstr(body).length;
            let t0 = P;
            run(body, false);
            txtb += P - t0;
        } else {
            bad("arch block tag " + tag);
        };
    };
    if (BAD == "" && P != body.length) { bad("arch set: " + tostring(P) + " of " + tostring(body.length) + " bytes used"); };
    "blocks " + tostring(n).pad_left(4) + " (" + tostring(shared) + " shared)  items " + tostring(irb).pad_left(6)
        + "  text " + tostring(txtb).pad_left(6)
};

// The pack payload: the last [8 digits][YCCPACK1] frame, decoded when its
// method byte says so; and the bytes it was stored in.
def payload_of(raw: [byte], stored: [long]) -> [byte] {
    let n = raw.length;
    if (n < 16 || from_bytes(raw[n - 8:]) != "YCCPACK1") { bad("no YCCPACK1 trailer"); return []; };
    let len_ = dec(raw[n - 16:n - 8]);
    let pack = raw[n - 16 - len_:n - 16];
    stored[0] = pack.length;
    if (pack.length > 0 && pack[0] == 1) { lz_decode(pack[1:]) } else { pack }
};

def pct(part: long, whole: long) -> str {
    let t = (part * 1000 + whole / 2) / whole;
    (tostring(t / 10) + "." + tostring(t % 10) + "%").pad_left(6)
};

/** The report for the pack in `path`, or "bad pack: ..." (then `ok[0]` is false). */
def stats(path: str, ok: [bool]) -> str {
    BAD = "";
    ok[0] = false;
    let stored: [long] = [0];
    let pack = payload_of(yt.bytes_of(path), stored);
    if (BAD != "") { return "bad pack: " + BAD; };
    let out: [str] = [];
    if (stored[0] != pack.length) {
        out += "stored " + tostring(stored[0]) + " bytes, decoded to " + tostring(pack.length);
    };
    let nl = 0;
    while (nl < pack.length && pack[nl] != 10) { nl += 1; };
    if (nl >= pack.length) { return "bad pack: no version line"; };
    let version = from_bytes(pack[0:nl]);
    let vnum = 0;
    foreach (w in version.split(" ")) {
        if (is_digits(bytes(w))) { vnum = dec(bytes(w)); };
    };
    let fields = ["files", "iface", "init", "bodies", "btext", "labels", "rodata", "globals"];
    if (vnum >= 8) { fields += "tys"; };
    let totals: [long] = [];
    foreach (f in fields) { totals += 0; };
    P = nl + 1;
    let cnt = num(pack, "unit count");
    let rows: [str] = [];
    let arch: [str] = [];
    let unit_stored = 0;
    for u in 0..cnt {
        let name = from_bytes(nstr(pack));
        let body = nstr(pack);
        if (BAD != "") { return "bad pack: " + BAD; };
        let at = P;
        unit_stored += body.length;
        let st = body.length;
        if (vnum >= 9 && body.length > 0 && body[0] == 1) { body = lz_decode(body[1:]); };
        if (vnum >= 11 && body.length > 4 && body[0] == 2) { body = lz_decode(body[5:]); };
        if (name.starts_with("arch.")) {
            let a = arch_set(body);
            arch += name.pad_right(16) + " stored " + tostring(st).pad_left(7) + "  decoded " + tostring(body.length).pad_left(7)
                + "  " + a;
        } else {
            let got = parse_fields(body, fields);
            if (BAD == "" && P != body.length) {
                bad("unit " + name + ": " + tostring(P) + " of " + tostring(body.length) + " field bytes used");
            };
            let big: [str] = [];
            for i in 0..fields.length {
                totals[i] += got[i];
                if (got[i] > 200) { big += fields[i] + "=" + tostring(got[i]); };
            };
            rows += name.pad_right(10) + " " + tostring(body.length).pad_left(8) + "   " + join(big, "  ");
        };
        if (BAD != "") { return "bad pack: " + BAD; };
        P = at;
    };
    if (P != pack.length) { return "bad pack: " + tostring(pack.length - P) + " bytes left after the units"; };
    out += "version " + version.trim();
    out += "payload " + tostring(pack.length) + " bytes, " + tostring(rows.length) + " units, " + tostring(arch.length) + " arch sets\n";
    if (vnum >= 9) {
        out += "units stored in " + tostring(unit_stored) + " bytes (frame " + tostring(pack.length - unit_stored) + ")\n";
    };
    out += arch;
    if (arch.length > 0) { out += ""; };
    out += rows;
    out += "";
    let whole = 0;
    foreach (t in totals) { whole += t; };
    if (whole == 0) { whole = 1; };
    // largest first
    let order: [long] = [];
    for i in 0..fields.length { order += i; };
    for i in 0..order.length {
        for j in i + 1..order.length {
            if (totals[order[j]] > totals[order[i]]) {
                let t = order[i];
                order[i] = order[j];
                order[j] = t;
            };
        };
    };
    foreach (i in order) {
        out += fields[i].pad_right(8) + " " + tostring(totals[i]).pad_left(8) + "  " + pct(totals[i], whole);
    };
    out += "TOTAL".pad_right(8) + " " + tostring(whole).pad_left(8);
    ok[0] = true;
    join(out, "\n") + "\n"
};

/** "Z of N": how many of the attached pack's N units are stored compressed;
"" unless the frame is plain and walks to its end exactly. */
def units_compressed(pack: [byte]) -> str {
    BAD = "";
    let p = pack[0:pack.length - 16];
    if (p.length < 13 || from_bytes(p[0:13]) != "ycc-std-pack ") { return ""; };
    P = 0;
    while (P < p.length && p[P] != 10) { P += 1; };
    P += 1;
    let cnt = num(p, "units");
    let z = 0;
    for i in 0..cnt {
        nstr(p);
        let body = nstr(p);
        if (body.length > 0 && (body[0] == 1 || body[0] == 2)) { z += 1; };
    };
    if (BAD != "" || P != p.length) { return ""; };
    tostring(z) + " of " + tostring(cnt)
};

/** `ytest pack-stats [--target] PACK`. */
def main(av: [str]) -> long {
    if (av.length == 2 && av[0] == "--target") {
        // what an in-tree codec is measured against: gzip -9 and xz -9 of the payload
        BAD = "";
        let stored: [long] = [0];
        let pack = payload_of(yt.bytes_of(av[1]), stored);
        if (BAD != "") { eputs("bad pack: " + BAD); return 1; };
        let f = yt.tmp("payload");
        fs.write_bytes(f, pack);
        let g = yt.num(yt.sh("gzip -9 -c " + yt.q(f) + " | wc -c").out.trim(), 1);
        let x = yt.num(yt.sh("xz -9 -c " + yt.q(f) + " | wc -c").out.trim(), 1);
        print("stored " + tostring(stored[0]));
        print("payload " + tostring(pack.length) + "  gzip -9 " + tostring(g) + "  xz -9 " + tostring(x));
        return 0;
    };
    if (av.length != 1) {
        eputs("usage: ytest pack-stats [--target] PACK-FILE");
        return 2;
    };
    let ok = [false];
    let s = stats(av[0], ok);
    if (ok[0]) { puts(s); 0 } else { eputs(s); 1 }
};

export { stats, lz_decode, units_compressed, dec, main };
