// su_gc.y -- the collector under a cap: the reason it exists.
//
// A threaded program once leaked everything it allocated after a spawn, so its
// memory grew with the WORK, not with what it kept. The collector now stops the
// world at the allocator's slow path and scans every thread's stack: two
// threads of 300k allocations (~90 MB of garbage) must run inside 64 MiB, and
// survive a cycle at every allocation (--gc=stress). Checked --gc=never
// must reject the workload instead of emitting an unbounded heap.
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

def run_mem(bin: str, secs: long, kb: long) -> str {
    let c = yt.cmd([bin]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.mem_kb = kb;
    c.timeout = secs * yt.SCALE;
    yt.run(c).out
};

def capped_run(bin: str, secs: long) -> str { run_mem(bin, secs, cap()) };

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
    // A thread parked in a blocking syscall (read on a pipe) must not stop the
    // collector: y_gc_syscall publishes it as stopped. Same cap.
    let sysf = yc.ROOT + "/test/y/native/t420_gc_thread_in_syscall.y";
    if (compile(cc, [], sysf, b + ".sys", 60)) {
        let g4 = capped_run(b + ".sys", 120);
        yt.check("gc [" + tag + "] a thread blocked in a syscall does not stop the collector",
            g4 == yt.read(yc.ROOT + "/test/y/native/t420_gc_thread_in_syscall.expected"), yt.clip(g4, 200));
    } else {
        yt.fail("gc [" + tag + "] compiles the thread-in-syscall fixture", "");
    };
    let st = yc.ROOT + "/test/y/native/t389_gc_stress_threads.y";
    if (compile(cc, ["--gc=stress"], st, b + ".st", 120)) {
        let g3 = capped_run(b + ".st", 300);
        yt.check("gc [" + tag + "] two threads survive a cycle at every allocation (--gc=stress)",
            g3 == yt.read(yc.ROOT + "/test/y/native/t389_gc_stress_threads.expected"), yt.clip(g3, 200));
    } else {
        yt.fail("gc [" + tag + "] compiles the --gc=stress fixture", "");
    };
    // Threads spawning threads at once, under --gc=stress: the registry of live
    // threads is updated by spawn and by an exiting thread, and an unlocked
    // update dropped a live thread from it (its stack unscanned, its start
    // closure freed under it). The race is timing, so the same binary runs a few
    // times: without the registry lock about a third of the runs crashed. The
    // cap is the ordinary program limit, not the small one: every thread maps an
    // 8 MiB stack of its own, and a dozen live threads need more than that.
    let storm = yc.ROOT + "/test/y/native/t406_threads_spawn_storm.y";
    if (compile(cc, ["--gc=stress"], storm, b + ".storm", 120)) {
        let want_storm = yt.read(yc.ROOT + "/test/y/native/t406_threads_spawn_storm.expected");
        let bad = 0;
        for i in 0..6 {
            if (run_mem(b + ".storm", 120, yc.PROG_MEM_KB) != want_storm) { bad = bad + 1; };
        };
        yt.check("gc [" + tag + "] threads spawning threads survive a cycle at every allocation (6 runs)",
            bad == 0, tostring(bad) + " of 6 runs failed");
    } else {
        yt.fail("gc [" + tag + "] compiles the --gc=stress spawn storm", "");
    };
    let ng = yt.cmd([cc, "--gc=never", thr, "-o", b + ".ng"]);
    ng.merge = true;
    let rejected = yt.run(ng);
    yt.check("gc [" + tag + "] --gc=never rejects the threaded allocation workload",
        rejected.code == 1 && rejected.out.contains("lifetime:"), yt.clip(rejected.out, 200));
};

def cases() -> [yt.Case] {
    [yt.case_excl("gc", "cycc", () => one("cycc", yc.CYCC)), yt.case_excl("gc", "ynew", () => one("ynew", yc.YREF))]
};

export { cases };
