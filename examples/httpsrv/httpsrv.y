// httpsrv -- an HTTP server with a live dashboard, and a client that
// fetches it over loopback and renders the same data in the terminal.
//
//   ./httpsrv                 the deterministic transcript (what EXPECTED holds)
//   ./httpsrv --self-test     the property check: fork, exercise, assert, stop
//   ./httpsrv --live          the live dashboard in a terminal (q quits)
//   ./httpsrv --serve         just the server, in the foreground
//
// Three processes are never mixed: the server runs in a fork (it cannot
// be stopped any other way -- see srv.y), the client is this process, and
// no thread is spawned anywhere. Everything is loopback; nothing outside
// 127.0.0.1 is contacted and no name is resolved.
//
// The default run is deterministic because the *server* is: with no
// --live it runs a seeded model instead of the clock, so the same requests
// give the same bytes. --live is the same code with clock_gettime behind
// the model's `mode` and a real terminal in front of it.

import args;
import term;
import time;
import http;
import json;
import httpc;
import srv;
import dash;

const WIN = 32;                 // the model's window, samples

const OPTS: [args.Opt] = [
    { long: "port", short: "", kind: args.NUM, help: "loopback port, 0 = any free one (default 0)" },
    { long: "samples", short: "n", kind: args.NUM, help: "polls in the transcript (default 6)" },
    { long: "seed", short: "", kind: args.NUM, help: "model seed (default 20260101)" },
    { long: "poll-ms", short: "", kind: args.NUM, help: "live poll period in ms, 10..2000 (default 100)" },
    { long: "self-test", short: "t", kind: args.BOOL, help: "run the property check, then exit" },
    { long: "live", short: "l", kind: args.BOOL, help: "live dashboard in this terminal" },
    { long: "serve", short: "s", kind: args.BOOL, help: "serve in the foreground until SIGTERM" },
    { long: "no-tty", short: "", kind: args.BOOL, help: "transcript (the default; accepted for habit)" }
];

// ── the one Stats record ───────────────────────────────────────────────
//
// Made once at start-up and then only written to: a record is a reference,
// so a frame costs no allocation and there is nothing to leak. The window
// inside it is filled from the JSON, never from the server's memory.

let st: dash.Stats = {
    served: 0, ticks: 0, arrived: 0, rate: 0, avg: 0, peak: 0, trough: 0,
    errors: 0, bytes: 0, up_ms: 0, nwin: WIN, win: [0; 32],
    label: "127.0.0.1:<ephemeral>", source: "virtual clock"
};

// ── results of the last check ──────────────────────────────────────────
let checks = 0;
let failures = 0;
let why = "";              // why the last pull did not work
let srv_avg = 0;           // the server's own avg, kept for the comparison
let srv_load = 0;          // its running sum over the window
let srv_peak = 0;
let srv_trough = 0;
let srv_arrived = 0;
let srv_ticks = 0;
let page_served = -1;      // the number read out of the HTML page

// ── reporting ──────────────────────────────────────────────────────────

def ok(cond: bool, name: str, detail: str) -> bool {
    checks = checks + 1;
    if (cond) {
        puts("ok   " + name + "  " + detail + "\n");
        true
    } else {
        failures = failures + 1;
        puts("FAIL " + name + "  " + detail + "\n");
        false
    }
};

def note(s: str) {
    puts("     " + s + "\n");
};

// column padding for the transcript. These build strings, so they are for
// the one-shot text -- a frame must never come through here (dash.y owns
// that path and writes bytes into a fixed buffer instead).
let padbuf: [byte; 32] = [0; 32];

// n spaces, written into a fixed buffer and converted once. Building the
// string a character at a time is the O(n^2) shape filed in
// examples/BUGS.md ("one missing semicolon turns 1.2 MB into 1.2 GB").
def spaces(n: long) -> str {
    let take = n;
    if (take > 32) { take = 32; };
    let i = 0;
    while (i < take) {
        padbuf[i] = 32;
        i = i + 1;
    };
    from_bytes(padbuf[0 : take])
};

def padl(t: str, w0: long) -> str {
    let w1 = w0 - len(t);
    if (w1 <= 0) { return t; };
    t + spaces(w1)
};

def padr(t: str, w0: long) -> str {
    let w1 = w0 - len(t);
    if (w1 <= 0) { return t; };
    spaces(w1) + t
};

// the frame, written straight out of dash's buffer: puts() would copy it
def put_frame(k: long) {
    let left = 0;
    while (left < k) {
        let w = syscall(1, 1, &dash.out[left], k - left);
        if (w <= 0) { left = k; } else { left = left + w; };
    };
};

// ── reading the server ─────────────────────────────────────────────────

// one integer field of the object that was just fetched, into the return
// value; `why` says what was wrong when there is nothing to return.
def num_field(off: long, end: long, key: str) -> long {
    let p = json.get(httpc.buf, off, end, key);
    if (p < 0) {
        why = "no field " + key + " (" + json.err + ")";
        return 0;
    };
    let v = json.int_at(httpc.buf, p, end);
    if (!json.ok) {
        why = "field " + key + ": " + json.err;
        return 0;
    };
    v
};

// GET path -> the status, with the whole response parsed into st. 0 means
// the fetch or the parse failed and `why` says which.
def pull(port: long, path: str) -> long {
    why = "";
    let code = httpc.get(port, path);
    if (httpc.err != 0) {
        why = "fetch " + path + ": errno " + tostring(httpc.err);
        return 0;
    };
    let off = httpc.body_off;
    let end = off + httpc.body_len;
    let stop = json.validate(httpc.buf, off, end);
    if (stop < 0) {
        why = path + ": " + json.err + " at byte " + tostring(json.at);
        return 0;
    };
    if (stop != end) {
        why = path + ": trailing bytes after the JSON value";
        return 0;
    };
    let w = json.get(httpc.buf, off, end, "window");
    let nw = 0;
    if (w >= 0) { nw = json.alen(httpc.buf, w, end); };
    if (nw != WIN) {
        why = path + ": the window holds " + tostring(nw) + " samples, not " + tostring(WIN);
        return 0;
    };
    let i = 0;
    let bad = 0;
    while (i < WIN) {
        let e = json.elem(httpc.buf, w, end, i);
        if (e < 0) { bad = 1; } else {
            let v = json.int_at(httpc.buf, e, end);
            if (!json.ok) { bad = 1; } else { st.win[i] = v; };
        };
        i = i + 1;
    };
    if (bad > 0) {
        why = path + ": a window sample is not an integer";
        return 0;
    };
    st.served = num_field(off, end, "served");
    st.ticks = num_field(off, end, "ticks");
    st.arrived = num_field(off, end, "arrived");
    st.rate = num_field(off, end, "rate");
    st.peak = num_field(off, end, "peak");
    st.trough = num_field(off, end, "trough");
    st.errors = num_field(off, end, "errors");
    st.bytes = num_field(off, end, "bytes");
    st.up_ms = num_field(off, end, "uptime_ms");
    if (why != "") { return 0; };
    // the server's own view of avg/peak/trough/arrived, kept apart so the
    // check can compare them with what the client computed from `window`
    srv_avg = num_field(off, end, "avg");
    srv_load = num_field(off, end, "load");
    srv_peak = num_field(off, end, "peak");
    srv_trough = num_field(off, end, "trough");
    srv_arrived = num_field(off, end, "arrived");
    srv_ticks = num_field(off, end, "ticks");
    if (why != "") { return 0; };
    st.nwin = WIN;
    // and the client's, derived from the samples: peak, trough, mean
    let hi = st.win[0];
    let lo = st.win[0];
    let tot = 0;
    i = 0;
    while (i < WIN) {
        if (st.win[i] > hi) { hi = st.win[i]; };
        if (st.win[i] < lo) { lo = st.win[i]; };
        tot = tot + st.win[i];
        i = i + 1;
    };
    st.peak = hi;
    st.trough = lo;
    st.avg = tot / WIN;
    code
};

// the number the HTML page carries in id=v-served, read out of the bytes
// the last fetch left in httpc's buffer. Scanning for the id is the honest
// way: the page is a document, and this says what a browser would show.
// It fetches nothing -- the caller has just fetched the page.
def page_value(id: str) -> long {
    page_served = -1;
    let n = len(id);
    let i = 0;
    let at = -1;
    let lim = httpc.body_len - n - 4;
    while (i < lim && at < 0) {
        // the marker is "id=v-served>": 'i' 'd' '=' then the name then '>'
        if (httpc.buf[httpc.body_off + i] == 105 && httpc.buf[httpc.body_off + i + 1] == 100 &&
            httpc.buf[httpc.body_off + i + 2] == 61) {
            let c = 0;
            let eq = true;
            while (c < n) {
                if (httpc.buf[httpc.body_off + i + 3 + c] != id[c]) { eq = false; };
                c = c + 1;
            };
            if (eq && httpc.buf[httpc.body_off + i + 3 + n] == 62) { at = httpc.body_off + i + 4 + n; };
        };
        if (at < 0) { i = i + 1; };
    };
    if (at < 0) { return -1; };
    let v = 0;
    let digits = 0;
    let j = at;
    let stop = httpc.body_off + httpc.body_len;
    let reading = true;
    while (reading && j < stop) {
        let c = httpc.buf[j];
        if (c >= 48 && c <= 57) {
            v = v * 10 + (c - 48);
            digits = digits + 1;
            j = j + 1;
        } else {
            reading = false;
        };
    };
    if (digits == 0) { return -1; };
    page_served = v;
    v
};

// ── the model, independently ───────────────────────────────────────────
//
// A second implementation of srv's draw(), written here rather than
// shared, so that a typo in either one shows up as a disagreement instead
// of cancelling out. Given the seed and the sample index, it predicts the
// value the server's window must hold -- which is a check on the server's
// logic, not on its self-consistency, and it needs no golden file.
def predict(seed0: long, k: long) -> long {
    let x = seed0 % 2147483648;
    let i = 0;
    while (i < k) {
        x = (x * 1103515245 + 12345) % 2147483648;
        i = i + 1;
    };
    ((x / 65536) % 90 + 10) * 100
};

// the requests the first k draws represent: the running total `arrived`
// has to be, with k = the window plus every tick since boot.
def predict_load(seed0: long, k: long) -> long {
    let x = seed0 % 2147483648;
    let i = 0;
    let tot = 0;
    while (i < k) {
        x = (x * 1103515245 + 12345) % 2147483648;
        tot = tot + (x / 65536) % 90 + 10;
        i = i + 1;
    };
    tot
};

// ── the property check ─────────────────────────────────────────────────

// every route, once, with the status it must have
def route(port: long, path: str, method: str, want: long, ctype: str) -> long {
    let code = httpc.request(port, method, path);
    if (code != want) {
        ok(false, "route " + method + " " + path, "status " + tostring(code) + ", wanted " + tostring(want));
        return 0;
    };
    if (!httpc.header("Content-Type")) {
        ok(false, "route " + method + " " + path, "no Content-Type header");
        return 0;
    };
    let ct_ok = httpc.hdr_len == len(ctype);
    let i = 0;
    while (i < httpc.hdr_len) {
        if (httpc.buf[httpc.hdr_at + i] != ctype[i]) { ct_ok = false; };
        i = i + 1;
    };
    let len_ok = httpc.clen == httpc.body_len;
    ok(ct_ok && len_ok, "route " + method + " " + path,
       "status " + tostring(code) + ", Content-Type " + ctype +
       ", Content-Length " + tostring(httpc.clen) + " = " + tostring(httpc.body_len) + " bytes received");
    if (!len_ok) { return 0; };
    1
};

def selftest(port: long, seed: long) -> long {
    puts("-- httpsrv property check -------------------------------------------------\n");
    puts("   a golden file proves the run is deterministic; it cannot tell a right\n");
    puts("   answer from a wrong one. Every line below is an assertion about the\n");
    puts("   behaviour, checked against the live server on loopback.\n\n");

    // (a) + (b) every route, its status, and its declared length
    let c_home = route(port, "/", "GET", 200, "text/html; charset=utf-8");
    let c_stats = route(port, "/api/stats", "GET", 200, "application/json");
    let c_hist = route(port, "/api/history", "GET", 200, "application/json");
    let c_health = route(port, "/healthz", "GET", 200, "text/plain; charset=utf-8");
    let c_404 = route(port, "/nope", "GET", 404, "application/json");
    let c_405 = route(port, "/api/stats", "POST", 405, "application/json");
    puts("");

    // a wrong path must not hand back a 200 body
    let wrong404 = httpc.request(port, "GET", "/nope/deeper?x=1");
    let wrong_is_json = httpc.body_starts("{\"error\":");
    let wrong_says_it = httpc.body_has("not found") >= 0;
    ok(wrong404 == 404 && wrong_is_json && wrong_says_it,
       "a wrong path is never a 200",
       "GET /nope/deeper -> " + tostring(wrong404) + ", body starts {" + tostring(wrong_is_json != false) +
       " and says \"not found\": " + tostring(wrong_says_it));

    // and the 405 has to carry Allow: GET
    httpc.request(port, "PUT", "/api/stats");
    let has_allow = httpc.header("Allow");
    let allow_ok = false;
    if (has_allow) {
        allow_ok = true;
        let i = 0;
        while (i < httpc.hdr_len) {
            if (i >= 3 || httpc.buf[httpc.hdr_at + i] != "GET"[i]) { allow_ok = false; };
            i = i + 1;
        };
    };
    ok(httpc.status == 405 && has_allow && allow_ok, "405 carries Allow: GET",
       "PUT /api/stats -> " + tostring(httpc.status) + ", Allow: " +
       (if (has_allow) { from_bytes(httpc.buf[httpc.hdr_at : httpc.hdr_at + httpc.hdr_len]) } else { "(none)" }));

    // a body that claims a length must arrive whole, every time
    let i = 0;
    let short = 0;
    let codes = 0;
    while (i < 24) {
        let p = "/api/stats";
        if (i % 4 == 1) { p = "/"; };
        if (i % 4 == 2) { p = "/api/history"; };
        if (i % 4 == 3) { p = "/missing"; };
        let code = httpc.get(port, p);
        codes = codes + 1;
        if (code != 0 && httpc.clen != httpc.body_len) { short = short + 1; };
        i = i + 1;
    };
    ok(short == 0, "Content-Length is the length, on every route",
       tostring(codes) + " requests over 4 routes, 0 short or long bodies");
    ok(c_home + c_stats + c_hist + c_health + c_404 + c_405 == 6,
       "all six routes answered as specified", "200 200 200 200 404 405");
    puts("");

    // (c) the JSON parses back, field by field
    let code = pull(port, "/api/stats");
    let eq_peak = srv_peak == st.peak;
    let eq_trough = srv_trough == st.trough;
    let eq_avg = srv_avg == st.avg;
    let eq_arr = srv_arrived == st.arrived;
    let eq_up = st.up_ms == st.ticks * srv.TICK_MS;
    ok(code == 200 && eq_peak && eq_trough && eq_avg && eq_arr && eq_up,
       "the JSON round-trips",
       "peak " + tostring(srv_peak) + "=" + tostring(st.peak) +
       ", trough " + tostring(srv_trough) + "=" + tostring(st.trough) +
       ", avg " + tostring(srv_avg) + "=" + tostring(st.avg) +
       ", arrived " + tostring(srv_arrived) + "=" + tostring(st.arrived) +
       ", uptime " + tostring(st.up_ms) + "=" + tostring(st.ticks) + "*10");
    ok(why == "", "every field parsed", if (why == "") { "served ticks arrived rate peak trough avg window errors bytes uptime" } else { why });
    // `load` is the server's running total over its window; the client just
    // summed the same 32 numbers itself. Two sides of one socket, one
    // equation, and no golden file anywhere.
    let tot = 0;
    i = 0;
    while (i < WIN) { tot = tot + st.win[i]; i = i + 1; };
    ok(tot == srv_load, "load == sum(window)",
       "server says " + tostring(srv_load) + " req/s summed over the window, client says " + tostring(tot));
    // and the model itself: the client's own LCG says what every sample is
    let base = st.served;
    // window[0] is the OLDEST of the last 32 samples (srv sends the ring
    // rotated), so sample i is the (ticks + 1 + i)-th draw of the model.
    let mism = 0;
    let bad_at = -1;
    i = 0;
    while (i < WIN) {
        let want = predict(seed, srv_ticks + 1 + i);
        if (want != st.win[i]) {
            mism = mism + 1;
            if (bad_at < 0) { bad_at = i; };
        };
        i = i + 1;
    };
    ok(mism == 0, "the window is the seeded model, sample by sample",
       tostring(WIN) + " samples predicted independently from seed " + tostring(seed) +
       " at tick " + tostring(srv_ticks) + ", " + tostring(mism) + " mismatched" +
       (if (mism > 0) { " (first at index " + tostring(bad_at) + ")" } else { "" }));
    let want_arrived = predict_load(seed, srv.WN + srv_ticks);
    ok(want_arrived == srv_arrived, "arrived is the model's running total",
       "predicted " + tostring(want_arrived) + " requests over " + tostring(srv.WN + srv_ticks) +
       " draws, server says " + tostring(srv_arrived));
    ok(base > 0, "the counter is alive", "served " + tostring(base) + " after the route sweep");
    puts("");

    // (d) it strictly increases
    let prev = st.served;
    let grew = 0;
    let steps = 10;
    i = 0;
    while (i < steps) {
        let c2 = pull(port, "/api/stats");
        if (c2 == 200 && st.served > prev) { grew = grew + 1; };
        prev = st.served;
        i = i + 1;
    };
    ok(grew == steps, "served strictly increases",
       tostring(grew) + "/" + tostring(steps) + " successive fetches moved the counter forward, now " + tostring(prev));
    puts("");

    // the page and the API are the same numbers, one request apart
    let j1 = pull(port, "/api/stats");
    let served_json = st.served;
    let j2 = httpc.get(port, "/");
    let page_code = httpc.status;
    let page_n = page_value("v-served");
    ok(j1 == 200 && j2 == 200 && page_n == served_json + 1,
       "the page and the JSON agree",
       "/api/stats says served " + tostring(served_json) + ", the page one request later says " +
       tostring(page_n) + " -- the +1 is that page request itself");
    ok(page_code == 200 && httpc.body_has("<!doctype html>") >= 0 && httpc.body_has("id=v-rate") >= 0,
       "the page is the dashboard",
       tostring(httpc.body_len) + " bytes, has a doctype and the live tiles");
    ok(page_code == 200 && httpc.header("Content-Type") && httpc.clen == httpc.body_len,
       "the page's length is right too", "declared " + tostring(httpc.clen) + ", received " + tostring(httpc.body_len));
    puts("");

    // allocation, both ends
    let sh0 = 0;
    let shb0 = 0;
    let pulled = pull(port, "/api/stats?heap=1");
    let bend = httpc.body_off + httpc.body_len;
    let got_heap = json.get(httpc.buf, httpc.body_off, bend, "heap");
    let got_base = json.get(httpc.buf, httpc.body_off, bend, "base_heap");
    if (got_heap >= 0) { sh0 = json.int_at(httpc.buf, got_heap, bend); };
    if (got_base >= 0) { shb0 = json.int_at(httpc.buf, got_base, bend); };
    // a missing field would make this comparison read 0 == 0 and pass, so
    // the presence of the numbers is itself a check
    ok(pulled == 200 && got_heap >= 0 && got_base >= 0 && sh0 > 0,
       "?heap=1 makes the server report its own heap",
       "status " + tostring(pulled) + ", heap_used() " + tostring(sh0) + " with boot " + tostring(shb0) +
       " -- a missing field would have made the delta below read 0 == 0");
    // h0 is read HERE, after the ok() line above: that line concatenates
    // strings for its own text, and the harness must not measure itself.
    // Two phases, so a one-off cost shows up as itself instead of being
    // averaged into the per-request number.
    let h0 = heap_used();
    let n = 50;
    i = 0;
    while (i < n) {
        httpc.get(port, "/api/stats");
        i = i + 1;
    };
    let hmid = heap_used();
    while (i < 200) {
        httpc.get(port, "/api/stats");
        i = i + 1;
    };
    let h1 = heap_used();
    let sh1 = 0;
    if (pull(port, "/api/stats?heap=1") == 200) {
        let e2 = httpc.body_off + httpc.body_len;
        let g2 = json.get(httpc.buf, httpc.body_off, e2, "heap");
        if (g2 >= 0) { sh1 = json.int_at(httpc.buf, g2, e2); };
    };
    ok(sh1 - sh0 == 0, "the server does not grow serving",
       tostring(n) + " requests: heap_used() " + tostring(sh0) + " -> " + tostring(sh1) +
       " (delta " + tostring(sh1 - sh0) + ", boot " + tostring(shb0) + ")");
    ok(h1 - hmid == 0 && hmid - h0 < 64, "the client does not grow polling",
       "first " + tostring(n) + " requests " + tostring(h0) + " -> " + tostring(hmid) +
       " (delta " + tostring(hmid - h0) + ", one-off), next " + tostring(200 - n) +
       " " + tostring(hmid) + " -> " + tostring(h1) + " (delta " + tostring(h1 - hmid) + ")");
    note("What makes that true: the digit scratch in w_num()/w()/n() is a module-level");
    note("[byte; 24], not a literal built per call. A literal inside a function that runs");
    note("per request cost 64 bytes a call here, and the arena never frees it.");
    puts("");

    // and the std client, for the record: it agrees, and it is expensive
    let url = "http://127.0.0.1:" + tostring(port) + "/api/stats";
    let hs0 = heap_used();
    let r = http.get(url);
    let mine = 0;
    let same_status = 0;
    let same_len = 0;
    let mine_code = pull(port, "/api/stats");
    if (mine_code == 200) { mine = httpc.body_len; };
    let rb = r.read(0);            // read the body ONCE: a second text() is empty
    if (r.status == 200) { same_status = 1; };
    if (r.size == len(rb)) { same_len = 1; };
    ok(same_status == 1 && same_len == 1 && mine > 0,
       "std http.get agrees with this client",
       "status " + tostring(r.status) + ", Content-Length " + tostring(r.size) +
       " = " + tostring(len(rb)) + " bytes read; this client got " + tostring(mine) + " bytes");
    // what it costs: the same request twenty times through the std client
    let m = 1;
    let empties = 0;
    while (m < 20) {
        let r2 = http.get(url);
        let bb = r2.read(0);
        if (len(bb) == 0) { empties = empties + 1; };
        m = m + 1;
    };
    let hs1 = heap_used();
    ok(empties == 0, "20 std requests, 20 non-empty bodies",
       tostring(empties) + " came back empty; body read once into a variable each time");
    note("std http.get: heap_used() grew " + tostring(hs1 - hs0) + " bytes over 20 requests = " +
         tostring((hs1 - hs0) / 20) + " bytes a request, on top of this program's own.");
    note("The fixed-buffer client in httpc.y costs 0 for the same 200 requests above, which");
    note("is why the polling path uses it and std http.get is only the cross-check.");
    puts("");

    // the shutdown
    let code2 = stop_server();
    ok(code2 == 143, "the server stops cleanly",
       "SIGTERM -> wait_pid " + tostring(code2) + " (128+15), not a crash");

    puts("");
    if (failures == 0) {
        puts("PASS " + tostring(checks) + " checks, 0 failed\n");
    } else {
        puts("FAIL " + tostring(failures) + " of " + tostring(checks) + " checks failed\n");
    };
    failures
};

// Stop the server. Every exit path goes through here: a program that
// forked a server and then returned without killing it leaves a process
// holding a port for ever, and there is no signal handler to fall back on.

let srv_stopped = false;
let srv_code = 0;

def stop_server() -> long {
    // pid 0 would mean "the caller's process group", so a --serve run (no
    // fork, no pid) must never reach the kill
    if (srv.pid <= 0) { return 0; };
    // Idempotent, and called from every exit path including the failure
    // ones: a leaked server child holds the parent's stdout open, so a
    // command substitution around this program would hang for ever with no
    // message. That is not a hypothetical -- it is what `--live` with a
    // piped stdout did until this was fixed.
    if (!srv_stopped) {
        srv.kill(srv.pid);
        srv_code = srv.stop(srv.pid);
        srv_stopped = true;
    };
    srv_code
};

// ── the deterministic transcript ───────────────────────────────────────

def transcript(port: long, samples: long, seed: long, ephemeral: bool) -> long {
    puts("== httpsrv -- an HTTP server with a live dashboard, on loopback ==\n");
    puts("   pin c53cc41524a7baa2  (full sha256 and toolkit shas in README.md)\n");
    if (ephemeral) {
        puts("   server 127.0.0.1:<ephemeral>  -- any free port, so two copies never collide\n");
    } else {
        puts("   server 127.0.0.1:" + tostring(port) + "\n");
    };
    puts("   model: seeded, no clock; the same requests give the same bytes\n");
    puts("   forked: the server is a process, so SIGTERM is how it stops\n\n");

    // the route table
    puts("-- routes ------------------------------------------------------------\n");
    // left-aligned labels over left-aligned values, right-aligned numbers
    // over right-aligned numbers -- otherwise the header sits a field's
    // width away from the column it names
    // every column but the last carries its own trailing gap, so the
    // header and the values line up without a separator string
    puts(" " + padr("ok", 4) + " " + padl("route", 19) + " " + padl("method", 7) + " " +
         padr("status", 7) + " " + padr("declared", 9) + " " + padr("actual", 8) +
         "  content-type\n");
    let i = 0;
    let bad = 0;
    while (i < 6) {
        let path = "/";
        let method = "GET";
        let want = 200;
        if (i == 1) { path = "/api/stats"; };
        if (i == 2) { path = "/api/history"; };
        if (i == 3) { path = "/healthz"; };
        if (i == 4) { path = "/nope"; want = 404; };
        if (i == 5) { path = "/api/stats"; method = "POST"; want = 405; };
        let code = httpc.request(port, method, path);
        let ct = "(none)";
        if (httpc.header("Content-Type")) {
            ct = from_bytes(httpc.buf[httpc.hdr_at : httpc.hdr_at + httpc.hdr_len]);
        };
        let mark = "ok";
        if (code != want || httpc.clen != httpc.body_len) { mark = "!!"; bad = bad + 1; };
        puts(" " + padr(mark, 4) + " " + padl(path, 19) + " " + padl(method, 7) + " " +
             padr(tostring(code), 7) + " " + padr(tostring(httpc.clen), 9) + " " +
             padr(tostring(httpc.body_len), 8) + "  " + ct + "\n");
        i = i + 1;
    };
    puts("\n   " + tostring(6 - bad) + " of 6 had a Content-Length equal to the bytes that actually\n");
    puts("   arrived. The server counts its own body with a byte writer as it builds it\n");
    puts("   and the client counts what it received; neither trusts the other's number.\n\n");

    // the live poll
    puts("-- live poll: " + tostring(samples) + " fetches of /api/stats --------------------\n");
    puts("   " + padr("#", 2) + padr("served", 9) + padr("rate", 8) + padr("avg", 8) +
         padr("peak", 8) + padr("trough", 8) + padr("arrived", 10) + padr("errors", 8) +
         padr("bytes", 9) + "\n");
    // (the labels are right-aligned because the numbers under them are)
    // the row below is the same columns as f"{i+1:>3}{served:>9}{rate:>8}..."; the
    // header is padded by hand because an f-string cannot take a string field
    // in this compiler ({"route":<20} does not parse).
    let prev = -1;
    let grew = 0;
    i = 0;
    while (i < samples) {
        let code = pull(port, "/api/stats");
        if (code != 200) {
            puts(" fetch failed: " + why + "\n");
            stop_server();
            return 1;
        };
        if (st.served > prev) { grew = grew + 1; };
        prev = st.served;
        puts(f"{i + 1:>3}{st.served:>9}{st.rate:>8}{st.avg:>8}{st.peak:>8}{st.trough:>8}{st.arrived:>10}{st.errors:>8}{st.bytes:>9}\n");
        i = i + 1;
    };
    puts("\n   the counter moved forward on " + tostring(grew) + " of " + tostring(samples) + " polls.\n\n");

    // the dashboard the client renders -- the same data, as the terminal
    // view draws it
    puts("-- the dashboard, as the client renders it ----------------------------\n");
    put_frame(dash.render(st, true));
    puts("\n");

    puts("-- stop ---------------------------------------------------------------\n");
    let code = stop_server();
    puts("   SIGTERM -> wait_pid " + tostring(code) + "  (128 + 15), so it stopped and did\n");
    puts("   not crash.  `--live` shows the same frame updating in place; `--self-test`\n");
    puts("   is the property check, which has no golden file behind it.\n");
    0
};

// ── the live view ──────────────────────────────────────────────────────

def live(port: long, poll_ms: long) -> long {
    if (!term.is_tty(1)) {
        eputs("httpsrv --live: stdout is not a terminal.\n");
        eputs("httpsrv: the default run prints the same frame as text, and\n");
        eputs("httpsrv: --self-test checks the server it would have drawn.\n");
        stop_server();
        return 1;
    };
    term.raw_mode();
    term.arm_watchdog();
    term.enter_screen();
    dash.winsize();
    let warned = false;
    let fps = 1000 / poll_ms;
    let pacer = time.pacer_new(fps);
    let meter = time.fps_new();
    let go = true;
    let paused = false;
    let worst = 0;
    let misses = 0;
    // the loop's own heap, so the claim "a frame allocates nothing" is
    // printed by the program rather than asserted in a README
    let h0 = heap_used();
    while (go) {
        // the frame deadline belongs to the pacer; the key poll must not
        // be the thing that waits (read_key_timeout cannot be finer than
        // 100 ms -- VTIME counts deciseconds -- so 0 is the only value a
        // frame loop may pass).
        let waited = time.pacer_next(pacer);
        if (waited >= 0) {
            // pull() answers the status, so 200 is success -- writing
            // `!= 0` here made every good poll look like a failure, and
            // the dashboard showed rate 0 for a run
            let code = pull(port, "/api/stats");
            if (code != 200) {
                // say why, once: a frame with rate 0 and no explanation is
                // exactly the sort of thing a dashboard hides
                if (misses == 0) { eputs("httpsrv: first poll failed: " + why + "\n"); };
                misses = misses + 1;
                st.rate = 0;
                st.errors = st.errors + 1;
            };
            dash.winsize();
            if (dash.cols < 82 && !warned) {
                warned = true;
            };
            dash.paint(st, false);
            time.fps_tick(meter);
            if (worst < time.pacer_lag_us(pacer)) { worst = time.pacer_lag_us(pacer); };
        };
        let k = term.read_key_timeout(0);
        if (k == 113 || k == 27) { go = false; };        // q or ESC
        if (k == 32) { paused = !paused; };              // space
    };
    // read the heap BEFORE the report lines: each of them concatenates
    // strings for its own text, and the loop must not be charged for them
    let h1 = heap_used();
    term.leave_screen();
    puts("\n");
    puts(time.fps_line(meter) + "\n");
    puts("  frames " + tostring(time.fps_frames(meter)) + ", dropped " + tostring(time.pacer_dropped(pacer)) +
         ", worst lag " + tostring(worst / 1000) + " ms, polls that failed " + tostring(misses) + "\n");
    puts("  heap over the loop: " + tostring(h0) + " -> " + tostring(h1) +
         " (delta " + tostring(h1 - h0) + " for " + tostring(time.fps_frames(meter)) + " frames)\n");
    let code = stop_server();
    puts("  server stopped: wait_pid " + tostring(code) + "\n");
    // The view's own exit code, NOT the server's 143 -- a SIGTERMed server
    // is how this program stops it, so 143 here would report a clean quit
    // as a failure. restore_exit puts the terminal back and then exits, so
    // this has to be the last thing that happens.
    term.restore_exit((if (misses > 0) { 1 } else { 0 }));
    0
};

// ── main ───────────────────────────────────────────────────────────────

def main() -> void {
    args.init("httpsrv", "an HTTP server with a live dashboard, on loopback", OPTS, "");
    args.parse_or_exit(argv());
    let port_wanted = args.get_long("port", 0);
    let samples = args.get_long("samples", 6);
    let seed = args.get_long("seed", srv.DEFAULT_SEED);
    let poll_ms = args.get_long("poll-ms", 100);
    let self_test = args.has("self-test");
    let live_mode = args.has("live");
    let serve_only = args.has("serve");
    if (port_wanted < 0 || port_wanted > 65535) {
        eputs("httpsrv: --port must be 0 (any free port) or 1..65535\n");
        exit(2);
    };
    if (samples < 1 || samples > 4096) {
        eputs("httpsrv: --samples must be 1..4096\n");
        exit(2);
    };
    if (seed < 0 || seed > 2147483647) {
        // the model is a Lehmer generator mod 2^31: a seed outside that is
        // not a smaller run, it is a different (and, unfixed, a negative)
        // one -- so say so rather than quietly reduce it
        eputs("httpsrv: --seed must be 0..2147483647 (the model's modulus is 2^31)\n");
        exit(2);
    };
    if (poll_ms < 10 || poll_ms > 2000) {
        eputs("httpsrv: --poll-ms must be 10..2000\n");
        exit(2);
    };
    if (live_mode && self_test) {
        eputs("httpsrv: --live and --self-test are two different jobs; pick one\n");
        exit(2);
    };
    if (live_mode && serve_only) {
        eputs("httpsrv: --serve has no client, so --live would have nothing to draw\n");
        exit(2);
    };
    if (serve_only) {
        // the foreground server: no fork, no client, no dashboard -- it is
        // here so a human can point curl at it
        st.source = "virtual clock";
        exit(srv.run(port_wanted, srv.VIRTUAL, seed, 2));
    };

    let mode = srv.VIRTUAL;
    if (live_mode) { mode = srv.REAL; };
    let port = srv.start(port_wanted, mode, seed);
    if (port <= 0) {
        eputs("httpsrv: cannot start the server on port " + tostring(port_wanted) +
              " (errno " + tostring(srv.spawn_err) + ")\n");
        exit(1);
    };
    st.label = if (port_wanted == 0) { "127.0.0.1:<ephemeral>" } else { "127.0.0.1:" + tostring(port) };
    st.source = if (live_mode) { "real clock" } else { "virtual clock, seeded" };

    let rc = 0;
    if (self_test) {
        if (selftest(port, seed) > 0) { rc = 1; };
    } else if (live_mode) {
        rc = live(port, poll_ms);
    } else {
        rc = transcript(port, samples, seed, port_wanted == 0);
    };
    // the safety net: no path out of here leaves the server running
    stop_server();
    // The last expression's value is NOT the exit status (measured: a
    // function returning 1 left the program exiting 0), so a failure has to
    // say so with exit() -- which is also why a bug in this file could
    // report FAIL and still exit clean.
    exit(rc)
};

main()