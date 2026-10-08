// yc.y -- the compilers under test, and the comparisons every suite makes.
//
// The toolchain is one implementation twice over (PORTING.md): CYCC is the C
// copy, YREF the blessed reference, YCC the built compiler. Every comparison
// here asks the two copies to agree: byte-identical binaries, the same
// warnings, the same behaviour.
import fs;
import yt;

let ROOT = "";
let CYCC = "";
let YREF = "";
let YCC = "";
// Flags on every compile a comparison drives ("-W 1" for the port gate's
// second pass).
let PROG_MEM_KB = 3670016;

def abs_path(p: str) -> str {
    if (p.starts_with("/")) { p } else { ROOT + "/" + p }
};

def init() {
    ROOT = fs.cwd();
    CYCC = abs_path(yt.env("CYCC", "cycc"));
    YREF = abs_path(yt.env("YREF", "refs/ycc.ref"));
    YCC = abs_path(yt.env("YCC", "ycc"));
    PROG_MEM_KB = yt.num(yt.env("YPROG_MEM_KB", "3670016"), 3670016);
    // A sanitized COMPILER runs ~15x slower and reserves terabytes of address
    // space: its timeouts scale and its cap is ASan's own RSS limit instead
    // (ASAN_OPTIONS=hard_rss_limit_mb). The programs it emits are plain static
    // ELFs and keep PROG_MEM_KB.
    foreach (s in ["asan", "msan", "ubsan"]) {
        if ((CYCC + YREF + YCC).contains(s)) {
            yt.SCALE = yt.num(yt.env("YTIMEOUT_SCALE", "15"), 15);
            yt.MEM_KB = 0;
        };
    };
};

def have_ycc() -> bool { fs.is_file(YCC) };

/** The path below ROOT, for a case name. */
def rel(p: str) -> str {
    if (p.starts_with(ROOT + "/")) { p[ROOT.length + 1:] } else { p }
};

/** `compiler flags... -o out file`, stdout and stderr together. */
def compile(compiler: str, flags: [str], file: str, out: str, secs: long) -> yt.Res {
    let c = yt.cmd([compiler] + flags + ["-o", out, file]);
    c.merge = true;
    c.timeout = secs * yt.SCALE;
    yt.run(c)
};

/** Run a built program: `secs` timeout, stdin from `stdin` ("" = /dev/null), output merged. */
def run_bin(bin: str, args: [str], stdin: str, secs: long) -> yt.Res {
    let c = yt.cmd([bin] + args);
    c.merge = true;
    c.stdin = stdin;
    c.timeout = secs;
    c.mem_kb = PROG_MEM_KB;
    yt.run(c)
};

def bar(s: str) -> str { yt.clip(s, 200) };

/** One file through both copies; both reject alike, or both emit the same bytes and warnings. */
def port_check(file: str, flags: [str], tag: str, gap: bool) {
    let name = rel(file) + (if (tag != "") { " (" + tag + ")" } else { "" });
    let br = yt.tmp("ref");
    let bc = yt.tmp("cop");
    let r = compile(YREF, flags, file, br, 300);
    let c = compile(CYCC, flags, file, bc, 300);
    if (r.code == 1 && c.code == 1) {
        yt.check(name + " (rejected by both)", r.out == c.out,
            "rejected by both, with different diagnostics: reference '" + bar(r.out) + "', copy '" + bar(c.out) + "'");
    } else if (r.code != 0 || c.code != 0) {
        yt.fail(name, "reference exit=" + tostring(r.code) + ", copy exit=" + tostring(c.code) + ": " + bar(c.out));
    } else if (!yt.same_file(br, bc)) {
        if (gap) {
            yt.skip(name, "imports net/tui: raw syscalls in a packed unit, a known PE gap");
        } else {
            yt.fail(name, "binaries differ: reference=" + tostring(yt.size(br)) + " bytes, copy="
                + tostring(yt.size(bc)) + " bytes");
        };
    } else if (r.out != c.out) {
        yt.fail(name, "different warnings: reference '" + bar(r.out) + "', copy '" + bar(c.out) + "'");
    } else {
        yt.pass(name);
    };
    fs.remove_file(br);
    fs.remove_file(bc);
};

/** What run_parity found: agreement, and each side's exit and output. */
type Par = { ok: bool, ref_ec: str, ref_out: str, cpy_ec: str, cpy_out: str };

/** Compile with both copies and run both: identical binaries, warnings, output, and exit 0 or 1. */
def parity(file: str, flags: [str]) -> Par {
    let br = yt.tmp("ref");
    let bc = yt.tmp("cop");
    let r = compile(YREF, flags, file, br, 60);
    let c = compile(CYCC, flags, file, bc, 60);
    let p: Par = { ok: false, ref_ec: "cf" + tostring(r.code), ref_out: r.out, cpy_ec: "cf" + tostring(c.code), cpy_out: c.out };
    if (r.code == 0 && c.code == 0) {
        let same_bin = yt.same_file(br, bc);
        let rr = run_bin(br, [], "", 10);
        let rc = run_bin(bc, [], "", 10);
        p.ref_ec = tostring(rr.code);
        p.cpy_ec = tostring(rc.code);
        p.ref_out = rr.out;
        p.cpy_out = rc.out;
        p.ok = same_bin && r.out == c.out && rr.out == rc.out && rr.code == rc.code && (rr.code == 0 || rr.code == 1);
        if (rr.out != rc.out) {
            p.ref_out = "(output differs)\n" + rr.out;
            p.cpy_out = "(output differs)\n" + rc.out;
        };
        if (!same_bin) {
            p.ref_out = "(binaries differ between compilers)\n" + p.ref_out;
            p.cpy_out = "(binaries differ between compilers)\n" + p.cpy_out;
        };
        if (r.out != c.out) {
            p.ref_out = "(warnings differ between compilers)\n" + r.out + "\n" + p.ref_out;
            p.cpy_out = "(warnings differ between compilers)\n" + c.out + "\n" + p.cpy_out;
        };
    };
    fs.remove_file(br);
    fs.remove_file(bc);
    p
};

/** parity as a reported case. */
def parity_case(name: str, file: str, n: long) {
    let p = parity(file, []);
    yt.check(name, p.ok, "REF(ec=" + p.ref_ec + "): " + yt.clip(p.ref_out, n) + " / COPY(ec=" + p.cpy_ec + "): "
        + yt.clip(p.cpy_out, n));
};

/** Compile with the reference and run it (`ytool.sh -q`): the compile's
warnings are dropped, a failed compile answers its diagnostics and exit 1. */
def ref_run(file: str, stdin: str, secs: long) -> yt.Res {
    let b = yt.tmp("rr");
    let r = compile(YREF, [], file, b, 60);
    if (r.code != 0) {
        return { code: 1, out: r.out, err: "", timed_out: r.timed_out, ms: r.ms, us: r.us };
    };
    let o = run_bin(b, [], stdin, secs);
    fs.remove_file(b);
    o
};

export { ROOT, CYCC, YREF, YCC, init, have_ycc, rel, abs_path, compile, run_bin, port_check, Par,
    parity, parity_case, ref_run, bar };
