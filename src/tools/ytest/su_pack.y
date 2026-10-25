// su_pack.y -- `ycc --pack`: the self-decompressing output.
//
// --pack writes STUB || BODY || LEN8 || "YCCPACK2" (ycc.y's pack section,
// src/y/packstub.y is the other half of the format). This suite pins: a
// packed program runs exactly like the plain one -- stdout, exit status,
// argv and the environment -- and is smaller; every method (store, fixed,
// lz, dynamic) decodes; cycc and ycc pack ordinary programs byte-identically;
// each packs ycc into a compiler that works without std sources and compiles
// the same bytes; the driver refuses the flag combinations it
// cannot honour; and the packed size is ratcheted.
import fs;
import yt;
import yc;
import zlib;

// The source every case compiles: argc, argv[0], whether the environment
// survived, then exit 7.
let SRC = "import fs;\n" +
    "def main(av: [str]) -> long {\n" +
    "    print(\"argc=\" + tostring(av.length) + \" argv0=\" + av[0]);\n" +
    "    let e = fs.getenv(\"YTEST_PACK_ENV\");\n" +
    "    if (e == none) { print(\" no-env\"); } else { print(\" env=\" + e!); };\n" +
    "    print(\"\\n\");\n" +
    "    exit(7);\n" +
    "    0\n" +
    "};\n" +
    "let r = main(argv());\n";

let METHODS = ["store", "fixed", "lz", "dynamic"];
let SIZES = "";

def ycc_bin() -> str { yc.abs_path(yt.env("YSELF", yc.YCC)) };

/* The program with YTEST_PACK_ENV set, so a run proves the stub passed the
 * environment through execveat. */
def run_env(bin: str, args: [str]) -> yt.Res {
    let c = yt.cmd([bin] + args);
    c.merge = true;
    c.mem_kb = yc.PROG_MEM_KB;
    c.timeout = 60;
    c.env = ["YTEST_PACK_ENV=pack-value"];
    yt.run(c)
};

// A packed program is the plain one, but smaller and with the trailer.
def run_case() {
    let d = yt.tmp_dir("pack-run");
    yt.write(d + "/p.y", SRC);
    let y = ycc_bin();
    let a = yc.compile(y, [], d + "/p.y", d + "/p", 120);
    let b = yc.compile(y, ["--pack"], d + "/p.y", d + "/pz", 120);
    if (a.code != 0 || b.code != 0) {
        yt.fail("packed program runs like the plain one",
            "compile exits " + tostring(a.code) + "/" + tostring(b.code) + ": " +
            yt.clip(a.out + b.out, 200));
    } else {
        let ra = run_env(d + "/p", ["x", "y"]);
        let rb = run_env(d + "/pz", ["x", "y"]);
        // argv[0] is the path each was invoked by, so it is normalized before
        // the comparison: everything else must be identical.
        let ao = ra.out.replace(d + "/p", "BIN");
        let bo = rb.out.replace(d + "/pz", "BIN");
        yt.check("packed program runs like the plain one",
            ra.code == 7 && ra.code == rb.code && ao == bo,
            "plain exit=" + tostring(ra.code) + " '" + yt.clip(ra.out, 120) +
            "' packed exit=" + tostring(rb.code) + " '" + yt.clip(rb.out, 120) + "'");
        let bts = yt.bytes_of(d + "/pz");
        yt.check("the trailer is YCCPACK2",
            bts.length > 16 && from_bytes(bts[bts.length - 8:bts.length]) == "YCCPACK2", "");
    };
    fs.remove_all(d);
};

// Every method decodes and runs the same.
def methods_case() {
    let d = yt.tmp_dir("pack-m");
    yt.write(d + "/p.y", SRC);
    let y = ycc_bin();
    let base = yc.compile(y, [], d + "/p.y", d + "/p", 120);
    if (base.code != 0) {
        yt.fail("--pack methods", "the plain compile failed: " + yt.clip(base.out, 200));
    } else {
        let want = run_env(d + "/p", ["m"]);
        foreach (m in METHODS) {
            let r = yc.compile(y, ["--pack=" + m], d + "/p.y", d + "/p." + m, 120);
            if (r.code != 0) {
                yt.fail("--pack=" + m, "compile exit " + tostring(r.code) + ": " + yt.clip(r.out, 160));
            } else {
                let got = run_env(d + "/p." + m, ["m"]);
                yt.check("--pack=" + m + " runs",
                    got.code == want.code && got.out.replace(d + "/p." + m, "BIN") ==
                        want.out.replace(d + "/p", "BIN"),
                    "exit=" + tostring(got.code) + " '" + yt.clip(got.out, 120) +
                    "' against '" + yt.clip(want.out, 120) + "'");
            };
        };
    };
    fs.remove_all(d);
};

// Ordinary payloads exercise both encoders. The bootstrap can preserve a
// compressed std pack: packed compilers must work without a source checkout.
def twin_case() {
    let d = yt.tmp_dir("pack-twin");
    yt.write(d + "/p.y", SRC);
    let y = ycc_bin();
    let c = yc.CYCC;
    foreach (m in METHODS) {
        let ry = yc.compile(y, ["--pack=" + m], d + "/p.y", d + "/y." + m, 120);
        let rc = yc.compile(c, ["--pack=" + m], d + "/p.y", d + "/c." + m, 120);
        yt.check("both compilers --pack=" + m + " byte-identically",
            ry.code == 0 && rc.code == 0 && yt.same_file(d + "/y." + m, d + "/c." + m),
            "exits " + tostring(ry.code) + "/" + tostring(rc.code) + " " +
            yt.clip(ry.out + rc.out, 160));
    };
    if (fs.is_file(y)) {
        let ry = yc.compile(y, ["--pack"], y, d + "/y.self", 300);
        let rc = yc.compile(c, ["--pack"], y, d + "/c.self", 300);
        let plain = yc.compile(y, [], d + "/p.y", d + "/plain", 120);
        foreach (cc in ["y", "c"]) {
            let built = if (cc == "y") { ry } else { rc };
            let cmd = yt.cmd([d + "/" + cc + ".self", "--gc=auto", "p.y", "-o", cc + ".bin"]);
            cmd.cwd = d;
            cmd.timeout = 120;
            let r = if (built.code == 0) { yt.run(cmd) } else { built };
            yt.check(cc + " packed compiler works without std sources",
                plain.code == 0 && r.code == 0 && yt.same_file(d + "/plain", d + "/" + cc + ".bin"),
                "exit " + tostring(r.code) + " " + yt.clip(r.out + r.err, 200));
        };
    };
    fs.remove_all(d);
};

// Packing the compiler itself gives a working compiler.
def self_case() {
    let d = yt.tmp_dir("pack-self");
    let y = ycc_bin();
    if (!fs.is_file(y)) {
        yt.skip("packed ycc", "run 'make ycc' first");
    } else {
        yt.write(d + "/p.y", SRC);
        let rz = yc.compile(y, ["--pack"], y, d + "/ycc.packed", 300);
        if (rz.code != 0) {
            yt.fail("packed ycc", "packing ./ycc failed: " + yt.clip(rz.out, 200));
        } else {
            let plain = yc.compile(y, [], d + "/p.y", d + "/p.plain", 120);
            let pk = yc.compile(d + "/ycc.packed", [], d + "/p.y", d + "/p.packed", 120);
            yt.check("the packed ycc compiles the same bytes",
                plain.code == 0 && pk.code == 0 && yt.same_file(d + "/p.plain", d + "/p.packed"),
                "exits " + tostring(plain.code) + "/" + tostring(pk.code) + " " + yt.clip(pk.out, 200));
            yt.check("the packed ycc is smaller", yt.size(d + "/ycc.packed") < yt.size(y),
                tostring(yt.size(d + "/ycc.packed")) + " against " + tostring(yt.size(y)));
        };
    };
    fs.remove_all(d);
};

// The combinations --pack cannot honour are driver errors, not silent no-ops.
def errors_case() {
    let d = yt.tmp_dir("pack-err");
    yt.write(d + "/p.y", SRC);
    let y = ycc_bin();
    // every message is asserted whole: the coverage suite looks for the
    // compiler's own template in these lines (test/COVERAGE.md)
    let bad = yc.compile(y, ["--pack=nope"], d + "/p.y", d + "/x", 60);
    yt.check("--pack rejects an unknown method",
        bad.code != 0 && bad.out == "ycc: --pack wants dynamic, store, fixed or lz, got 'nope'\n",
        yt.clip(bad.out, 160));
    let s = yc.compile(y, ["--pack", "--emit=asm"], d + "/p.y", d + "/x", 60);
    yt.check("--pack with --emit=asm is refused",
        s.code != 0 && s.out == "ycc: --pack does not combine with --emit=asm\n", yt.clip(s.out, 160));
    let e = yc.compile(y, ["--pack", "--emit=source"], d + "/p.y", d + "/x", 60);
    yt.check("--pack with --emit=source is refused",
        e.code != 0 && e.out == "ycc: --pack does not combine with --emit=source\n", yt.clip(e.out, 160));
    let k = yc.compile(y, ["--pack", "--target=kernel"], d + "/p.y", d + "/x", 60);
    yt.check("--pack with --target=kernel is refused",
        k.code != 0 && k.out == "ycc: --pack is Linux ELF only (--target=kernel is not packed)\n",
        yt.clip(k.out, 160));
    let w = yc.compile(y, ["--pack", "--target=win"], d + "/p.y", d + "/x", 60);
    yt.check("--pack with --target=win is refused",
        w.code != 0 && w.out == "ycc: --pack is Linux ELF only (--target=win is not packed)\n",
        yt.clip(w.out, 160));
    let r = yc.compile(y, ["--pack", "run"], d + "/p.y", d + "/x", 60);
    yt.check("--pack with run is refused",
        r.code != 0 && r.out == "ycc: --pack does not combine with run\n", yt.clip(r.out, 160));
    let sp = yc.compile(y, ["--pack", "--std-pack", d + "/x.pack"], d + "/p.y", d + "/x", 60);
    yt.check("--pack with --std-pack is refused",
        sp.code != 0 && sp.out == "ycc: --pack does not combine with --std-pack\n", yt.clip(sp.out, 160));
    foreach (header in [[127, 69, 76, 70], [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 40, 0]]) {
        let malformed: [byte] = [];
        foreach (b in header) { malformed += b; };
        fs.write_bytes(d + "/foreign", malformed);
        let foreign = yc.compile(y, ["--pack"], d + "/foreign", d + "/x", 60);
        yt.check("--pack refuses a truncated or foreign ELF",
            foreign.code != 0 && foreign.out.contains("error: --pack needs a Linux x86-64 or AArch64 ELF64 executable"), yt.clip(foreign.out, 200));
    };
    fs.remove_all(d);
};

// `name number` lines of the size file, comments skipped.
def ratchet_get(name: str) -> long {
    let t = fs.read_file(SIZES);
    if (t == none) { return -1; };
    let out = -1;
    foreach (l in yt.lines(unwrap(t))) {
        let w = yt.words(l);
        if (w.length == 2 && !l.starts_with("#") && w[0] == name) {
            out = yt.num(w[1], -1);
        };
    };
    out
};

// The packed size of one fixed source: growth fails, shrinkage asks for the
// file to be updated (test/pack/sizes.txt).
def ratchet_case() {
    let d = yt.tmp_dir("pack-size");
    yt.write(d + "/p.y", SRC);
    let y = ycc_bin();
    let r = yc.compile(y, ["--pack"], d + "/p.y", d + "/p.packed", 120);
    if (r.code != 0) {
        yt.fail("packed size", yt.clip(r.out, 200));
    } else {
        let known = ratchet_get("src_dynamic");
        let got = yt.size(d + "/p.packed");
        if (known < 0) {
            yt.fail("src_dynamic is not in " + yc.rel(SIZES), "");
        } else if (got > known) {
            yt.fail("src_dynamic " + tostring(got) + " bytes (was " + tostring(known) + ")", "");
        } else if (got < known) {
            yt.pass("src_dynamic " + tostring(got) + " bytes, DOWN from " + tostring(known) +
                " (update " + yc.rel(SIZES) + ")");
        } else {
            yt.pass("src_dynamic " + tostring(got) + " bytes");
        };
    };
    fs.remove_all(d);
};

// The encoder's own round trip: the driver only checks the ELF magic, so a
// synthetic payload can carry arbitrary bytes through the whole pack path.
// The body is then decoded with std/zlib.y's inflate -- a second decoder, and
// the one the stub itself uses -- and compared byte for byte. This is the case
// that catches a malformed Huffman tree (a distance tree with one code too
// many, say) that no amount of real payloads would necessarily reach.
def encoder_case() {
    let d = yt.tmp_dir("pack-enc");
    let y = ycc_bin();
    // patterned and pseudo-random bytes, so literals, matches and both tree
    // shapes are exercised
    let p: [byte] = [];
    let seed = 12345;
    for i in 0..300000 {
        seed = (seed * 1103515245 + 12345) & 2147483647;
        if (i % 7 < 3) { p += i % 251; } else { p += (seed >> 16) & 255; };
    };
    let payload: [byte] = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 62, 0];
    payload += p;
    fs.write_bytes(d + "/s.bin", payload);
    foreach (m in ["store", "fixed", "dynamic"]) {
        let r = yc.compile(y, ["--pack=" + m], d + "/s.bin", d + "/s." + m, 180);
        if (r.code != 0) {
            yt.fail("--pack=" + m + " a synthetic payload", yt.clip(r.out, 160));
        } else {
            let b = yt.bytes_of(d + "/s." + m);
            let n = 0;
            for i in (b.length - 16)..(b.length - 8) { n = n * 10 + (b[i] - 48); };
            let body = b[b.length - 16 - n:b.length - 16];
            let data = body[5:body.length];
            let got = if (m == "store") { some(data) } else { zlib.inflate(data, 4000000) };
            let same = got != none && len(unwrap(got)) == payload.length;
            if (same) {
                let u = unwrap(got);
                for i in 0..payload.length { if (u[i] != payload[i]) { same = false; break; }; };
            };
            yt.check("--pack=" + m + " round-trips a synthetic payload", same,
                "decoded " + (if (got == none) { "none" } else { tostring(len(unwrap(got))) }) +
                " of " + tostring(payload.length));
        };
    };
    fs.remove_all(d);
};

def cases() -> [yt.Case] {
    SIZES = yc.ROOT + "/test/pack/sizes.txt";
    // twin and self pack the 1.7 MB compiler itself (a 3 MB deflate each), so
    // they ask for the machine to themselves: --gc=stress's thread storm is
    // timing sensitive and a second CPU-heavy case beside it can tip it over
    [yt.case_of("pack", "run", run_case),
     yt.case_of("pack", "methods", methods_case),
     yt.case_excl("pack", "twin", twin_case),
     yt.case_excl("pack", "self", self_case),
     yt.case_of("pack", "errors", errors_case),
     yt.case_of("pack", "encoder", encoder_case),
     yt.case_of("pack", "ratchet", ratchet_case)]
};

export { cases };
