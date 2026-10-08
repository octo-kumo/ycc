// su_gc.y -- the collector under a cap: the reason it exists.
//
// A threaded program once leaked everything it allocated after a spawn, so its
// memory grew with the WORK, not with what it kept. The collector now stops the
// world at the allocator's slow path and scans every thread's stack: two
// threads of 300k allocations (~90 MB of garbage) must run inside 64 MiB, and
// survive a cycle at every allocation (--gc-stress). --gc=never is the
// control: without the collector the same workload must not fit.
import fs;
import yt;
import yc;

def cap() -> long { yt.num(yt.env("YGC_CAP_KB", "65536"), 65536) };

def compile(cc: str, flags: [str], src: str, out: str, secs: long) -> bool {
    let c = yt.cmd([cc] + flags + [src, "-o", out]);
    c.cwd = yc.ROOT;
    c.mem_kb = yc.PROG_MEM_KB;
    c.timeout = secs * yt.SCALE;
    yt.run(c).code == 0
};

def capped_run(bin: str, secs: long) -> str {
    let c = yt.cmd([bin]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.mem_kb = cap();
    c.timeout = secs * yt.SCALE;
    yt.run(c).out
};

def one(tag: str, cc: str) {
    if (!fs.is_file(cc)) {
        yt.skip("gc [" + tag + "]", cc + " not built");
        return;
    };
    let thr = yc.ROOT + "/test/y/native/t385_gc_threads_alloc.y";
    let want = "7088890\n7088890\n";
    let b = yt.tmp("thr");
    let mib = tostring(cap() / 1024);
    if (!compile(cc, [], thr, b, 60)) {
        yt.fail("gc [" + tag + "] compiles the threaded allocation fixture", "");
        return;
    };
    let got = capped_run(b, 120);
    yt.check("gc [" + tag + "] two threads x 300k allocations fit in " + mib + " MiB", got == want, yt.clip(got, 200));
    let st = yc.ROOT + "/test/y/native/t389_gc_stress_threads.y";
    if (compile(cc, ["--gc-stress"], st, b + ".st", 120)) {
        let g3 = capped_run(b + ".st", 300);
        yt.check("gc [" + tag + "] two threads survive a cycle at every allocation (--gc-stress)",
            g3 == yt.read(yc.ROOT + "/test/y/native/t389_gc_stress_threads.expected"), yt.clip(g3, 200));
    } else {
        yt.fail("gc [" + tag + "] compiles the --gc-stress fixture", "");
    };
    if (compile(cc, ["--gc=never"], thr, b + ".ng", 60)) {
        let g2 = capped_run(b + ".ng", 120);
        if (g2 == want) {
            yt.fail("gc [" + tag + "] --gc=never fits the cap", "the fixture does not discriminate");
        } else {
            yt.pass("gc [" + tag + "] --gc=never runs out of memory on the same workload");
        };
    };
};

def cases() -> [yt.Case] {
    [yt.case_of("gc", "cycc", () => one("cycc", yc.CYCC)), yt.case_of("gc", "ynew", () => one("ynew", yc.YREF))]
};

export { cases };
