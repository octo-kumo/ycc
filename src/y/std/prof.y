// std/prof.y — per-function profiling runtime, spliced only in `ycc --prof`
// builds (native_resolve knows the flag). The emitter wraps every function
// with a call to y_prof_enter/y_prof_exit and the report lands on stderr
// when the process exits.
//
// What each row means (one per instrumented function, worst first):
//   calls    how many times the function was entered (exact)
//   total_ns cpu time inside it, callees included — for a recursive
//            function this counts the nesting per level (CLOCK_PROCESS_CPUTIME_ID)
//   self_ns  total_ns minus what it spent in callees: the function itself
//   avg_ns   self_ns / calls: the average time in the function's own body
//   max_ns   the single longest call, callees included
//
// Timing costs two clock_gettime calls per function call (~200 ns on a
// quiet machine), so absolute numbers carry that overhead: a function
// whose body is a few instructions looks slower than it is. Call counts
// are exact, and the overhead is identical on both sides of a branch
// comparison, so ratios stay meaningful — compare rows, not absolutes.
//
// STATE is a record of one flat zeroed [long] table, the per-slot name
// strings and the heap break at startup; the emitter allocates it in
// _start and keeps its address in %r13, passing it to every call:
//   tab[0] nslots   tab[1] depth   tab[2] guard (nonzero while in here)
//   tab[3], tab[4] the clock scratch (a timespec — no per-call allocation)
//   per slot s:  5+5*s .. calls, total_ns, max_ns, child_ns, unused
//   per frame j: 5+5*nslots+3*j .. slot, enter_ns, child_ns
// The guard makes re-entry harmless: anything the profiler itself calls is
// measured with its enter/exit pair skipped symmetrically, so nothing
// recurses and no frame is ever half-accounted.

def y_prof_init(n: long) -> { tab: [long], names: [str], heap0: long } {
    let tab: [long] = [];
    let total = 5 + 5 * n + 3 * 1024;
    let i = 0;
    while (i < total) {
        tab += 0;
        i = i + 1;
        0
    };
    tab[0] = n;
    let names: [str] = [];
    i = 0;
    while (i < n) {
        names += "";
        i = i + 1;
        0
    };
    { tab: tab, names: names, heap0: syscall(12, 0) }
};

// The cpu clock in nanoseconds (CLOCK_PROCESS_CPUTIME_ID). The timespec
// lives in the table: a per-call `[long; 2]` would allocate a heap block
// (two brk syscalls) and dominate what is being measured.
def y_prof_now(t: [long]) -> long {
    syscall(228, 2, &t[3]);
    t[3] * 1000000000 + t[4]
};

// Called from every instrumented prologue (arg pushed as the function's
// label string; stored once, on the first call).
def y_prof_enter(st: { tab: [long], names: [str], heap0: long }, slot: long, name: str) -> long {
    let t = st.tab;
    if (t[2] != 0) {
        0
    } else {
        t[2] = 1;
        let names = st.names;
        if (len(names[slot]) == 0) {
            names[slot] = name;
            0
        } else { 0; };
        let d = t[1];
        let j = d;
        if (j >= 1024) {
            j = 1023;
            0
        } else { 0; };
        let sb = 5 + 5 * t[0] + 3 * j;
        t[sb] = slot;
        t[sb + 1] = y_prof_now(t);
        t[sb + 2] = 0;
        t[1] = d + 1;
        t[2] = 0;
        0
    }
};

// Called at every instrumented exit (the one epilogue all returns funnel
// through). Pops the frame, books the call, and hands its duration to the
// caller's frame as child time.
def y_prof_exit(st: { tab: [long], names: [str], heap0: long }) -> long {
    let t = st.tab;
    if (t[2] != 0) {
        0
    } else {
        t[2] = 1;
        let d = t[1];
        if (d > 0) {
            t[1] = d - 1;
            let j = d - 1;
            if (j >= 1024) {
                j = 1023;
                0
            } else { 0; };
            let sb = 5 + 5 * t[0] + 3 * j;
            let slot = t[sb];
            let dur = y_prof_now(t) - t[sb + 1];
            let eb = 5 + 5 * slot;
            t[eb] = t[eb] + 1;
            t[eb + 1] = t[eb + 1] + dur;
            if (dur > t[eb + 2]) {
                t[eb + 2] = dur;
                0
            } else { 0; };
            t[eb + 3] = t[eb + 3] + t[sb + 2];
            let pj = d - 2;
            if (pj >= 0) {
                if (pj >= 1024) {
                    pj = 1023;
                    0
                } else { 0; };
                let pb = 5 + 5 * t[0] + 3 * pj;
                t[pb + 2] = t[pb + 2] + dur;
                0
            } else { 0; };
            0
        } else { 0; };
        t[2] = 0;
        0
    }
};

// The display name behind a label: `yfn_12_foo$3` -> `foo`, `y_print_long`
// stays as it is. The uid and rename's `$N` are not stable across
// branches, so they are stripped to make rows comparable.
def y_prof_name(lbl: str) -> str {
    let s = lbl;
    if (substr(s, 0, 4) == "yfn_") {
        s = substr(s, 4, len(s) - 4);
        let u = index_of(s, "_");
        if (u >= 0) {
            s = substr(s, u + 1, len(s) - u - 1);
            0
        } else { 0; };
        0
    } else { 0; };
    let d = last_index_of(s, "$");
    if (d > 0) {
        let rest = substr(s, d + 1, len(s) - d - 1);
        let digits = true;
        if (len(rest) == 0) {
            digits = false;
            0
        } else { 0; };
        let i = 0;
        while (i < len(rest)) {
            let c = substr(rest, i, 1);
            if (c >= "0") {
                if (c <= "9") { 0; } else { digits = false; 0; };
                0
            } else {
                digits = false;
                0
            };
            i = i + 1;
            0
        };
        if (digits) {
            s = substr(s, 0, d);
            0
        } else { 0; };
        0
    } else { 0; };
    s
};

// Right-align s in w columns.
def y_prof_pad(s: str, w: long) -> str {
    let r = s;
    while (len(r) < w) {
        r = " " + r;
        0
    };
    r
};

// Print the report to stderr: the summary line, then the column header, then
// one row per function that ran, worst (total_ns) first. Frames still in
// flight (the program left through exit()) are booked first, so nothing is
// lost.
def y_prof_report(st: { tab: [long], names: [str], heap0: long }) -> long {
    let t = st.tab;
    let names = st.names;
    let unwinding = true;
    while (unwinding) {
        if (t[1] > 0) {
            y_prof_exit(st);
            0
        } else {
            unwinding = false;
            0
        };
        0
    };
    t[2] = 1;
    let n = t[0];
    // slots that ran, sorted by total_ns descending (insertion sort)
    let idx: [long] = [];
    let i = 0;
    while (i < n) {
        if (t[5 + 5 * i] > 0) {
            idx += i;
            0
        } else { 0; };
        i = i + 1;
        0
    };
    let m = len(idx);
    let a = 1;
    while (a < m) {
        let v = idx[a];
        let vt = t[5 + 5 * v + 1];
        let b = a - 1;
        let go = true;
        while (go) {
            if (b >= 0) {
                if (t[5 + 5 * idx[b] + 1] < vt) {
                    idx[b + 1] = idx[b];
                    b = b - 1;
                    0
                } else {
                    go = false;
                    0
                };
                0
            } else {
                go = false;
                0
            };
            0
        };
        idx[b + 1] = v;
        a = a + 1;
        0
    };
    let calls = 0;
    let total = 0;
    i = 0;
    while (i < m) {
        let eb = 5 + 5 * idx[i];
        calls = calls + t[eb];
        total = total + (t[eb + 1] - t[eb + 3]);
        i = i + 1;
        0
    };
    eputs("prof: " + tostring(m) + " fns " + tostring(calls) + " calls "
        + tostring(total) + " ns cpu " + tostring(heap_used() - st.heap0) + " B alloc\n");
    eputs(y_prof_pad("calls", 10) + y_prof_pad("total_ns", 14)
        + y_prof_pad("self_ns", 14) + y_prof_pad("avg_ns", 12)
        + y_prof_pad("max_ns", 12) + "  name\n");
    i = 0;
    while (i < m) {
        let eb = 5 + 5 * idx[i];
        let c = t[eb];
        let tot = t[eb + 1];
        let selfns = tot - t[eb + 3];
        let nm = names[idx[i]];
        eputs(y_prof_pad(tostring(c), 10) + y_prof_pad(tostring(tot), 14)
            + y_prof_pad(tostring(selfns), 14) + y_prof_pad(tostring(selfns / c), 12)
            + y_prof_pad(tostring(t[eb + 2]), 12) + "  " + y_prof_name(nm) + "\n");
        i = i + 1;
        0
    };
    eputs("prof-end\n");
    t[2] = 0;
    0
};

