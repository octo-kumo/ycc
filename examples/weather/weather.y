// weather -- a weather client and renderer that is hermetic by default.
//
// Three legs, and only the first one runs unless asked:
//
//   1. plain HTTP   a forked local service on loopback serving canned
//                   weather JSON. Deterministic, offline, and what
//                   EXPECTED is. This is the default.
//   2. TLS          the same bytes over real TLS 1.3, from `openssl
//                   s_server` with a certificate this run generated, the
//                   client verifying it with `anchors:` (PEM text, not a
//                   path -- it goes straight to x509.anchors_pem).
//                   Still no internet. --tls
//   3. live         open-meteo.com, which needs no API key. Never in the
//                   default path and never in EXPECTED, because it
//                   depends on a third party and may rate-limit.
//                   --live
//
// ── the two facts that shape the client ────────────────────────────────
//
// Response.text() is READ-ONCE. Reading it twice silently yields "" the
// second time, and fs.write_file then writes a 0-byte file and returns
// true. That is examples/BUGS.md, "A second `Response.text()` is silently
// empty, and `fs.write_file` then writes a 0-byte file and returns true".
// So text() is called exactly once per response, its result is kept in
// this struct, and every later read of the body is a read of that field.
//
// net.listen_http never returns and has no shutdown path, so the local
// service is a forked child that is SIGTERM'd (syscall 62) when the parent
// is finished with it; the child then reports 143.
//
// ── exit codes ─────────────────────────────────────────────────────────
//
//   0  a report was printed, or --check passed
//   1  the service, the parser or a check failed -- nothing is printed
//      but the reason, and no partial report ever is
//   2  the command line was wrong

import net;
import http;
import fs;
import json;
import args;
import wxfmt;
import wxdata;
import wxsrv;
import wxrep;
import wxlive;
import selftest;

const TAG = "wx.v1";

// ── the client ──────────────────────────────────────────────────────────
//
// One struct per response, holding the body AFTER the single text() call.
// err is "transport" when no status arrived at all, "status" when the
// service answered with something other than 200, and "" on success.

type Fetch = { ok: bool, status: long, reason: str, body: str, err: str, msg: str };

// Everything that happens after the response arrives, including THE single
// text() call. Keeping it in one place is what makes "read it exactly once"
// a property of the code rather than a promise: there is no second path.
def take(r: http.Response) -> Fetch {
    if (r.status == 0) {
        { ok: false, status: 0, reason: "", body: "", err: "transport", msg: r.err }
    } else {
        let body = r.text();               // EXACTLY ONCE. See the header.
        { ok: r.status == 200, status: r.status, reason: r.reason, body: body,
          err: r.status == 200 ? "" : "status", msg: r.err }
    }
}

// Plain HTTP -- the default leg, and every --live request.
def fetch_plain(url: str, timeout: long = 10) -> Fetch {
    take(http.get(url, { timeout: timeout }))
}

// TLS with the certificate this run generated as the ONLY anchor. `anchors`
// is PEM TEXT, not a path: http hands it straight to x509.anchors_pem().
def fetch_pinned(url: str, pem: str, timeout: long = 10) -> Fetch {
    take(http.get(url, { timeout: timeout, anchors: some(pem) }))
}

// The message the service sent in its JSON error body, or a plain
// description of the status. Prefers what the peer actually said, because a
// report that quotes the service is more use than one that guesses.
def errmsg(f: Fetch) -> str {
    if (f.err == "transport") { return "no response from the service: " + f.msg };
    let d = json.parse(f.body);
    if (d.ok) {
        let e = json.obj(d.val, "error");
        if (e.kind == "obj") {
            return "HTTP " + tostring(f.status) + " " + f.reason + ": "
                 + json.str_of(e, "message") + " [" + json.str_of(e, "code") + "]";
        };
    };
    "HTTP " + tostring(f.status) + " " + f.reason
};

// A 200 whose body is not this service's document. One message, one exit,
// and no report -- a client that rendered what it could parse would be
// printing a lie with blanks in it.
def bad_doc(f: Fetch, why: str) -> Fetch {
    { ok: false, status: f.status, reason: f.reason, body: "", err: "document", msg: why }
};

def need(f: Fetch, why: str) -> Fetch {
    if (!f.ok) { return f };
    let d = json.parse(f.body);
    if (!d.ok) { return bad_doc(f, "the body is not JSON at byte " + tostring(d.at) + ": " + d.err) };
    if (json.str_of(d.val, "schema") != TAG) {
        return bad_doc(f, "expected schema " + TAG + ", got \""
                     + json.str_of(d.val, "schema") + "\"");
    };
    if (!json.has(d.val, "location") || !json.has(d.val, "current")
        || !json.has(d.val, "daily")) {
        return bad_doc(f, "the document has no location, current or daily section");
    };
    f
};

// ── the local service, in a forked child ────────────────────────────────

type Served = { pid: long, port: long };

def serve_local() -> Served {
    let lfd = net.socket_tcp();
    let b = net.bind_tcp(lfd, 0);          // 0: the kernel picks a free port,
    if (b < 0) {                           // so two copies never collide and
        eputs("weather: cannot bind a loopback socket: errno " + tostring(b) + "\n");
        exit(1);
    };
    let port = net.local_port(lfd);
    if (net.listen_fd(lfd, 16) < 0) {
        eputs("weather: cannot listen on the loopback socket" + "\n");
        exit(1);
    };
    let pid = fork { wxsrv.serve_forever(lfd); 0 };
    net.close_fd(lfd);                     // the parent's copy; the child has its own
    { pid: pid, port: port }
};

def stop(s: Served) -> long {
    syscall(62, s.pid, 15);
    wait_pid(s.pid)
};

// ── leg 1 and leg 2: render one city, or all of them ───────────────────
//
// Each of these takes the Fetch rather than a URL, so the request is made
// in one place and the ONE text() read has already happened. Nothing below
// this line can touch the socket.

def show(f: Fetch, days: long) -> long {
    if (!f.ok) {
        eputs("weather: " + errmsg(f) + "\n");
        return 1;
    };
    let g = need(f, "");
    if (!g.ok) {
        eputs("weather: " + g.msg + "\n");
        return 1;
    };
    let d = json.parse(g.body);
    let out = wxrep.render(d.val, days);
    if (out.length > 0) { print(out.trim()) };
    0
};

def show_all(f: Fetch, kind: str, days: long) -> long {
    if (!f.ok) {
        eputs("weather: " + errmsg(f) + "\n");
        return 1;
    };
    let g = need(f, "");
    if (!g.ok) {
        eputs("weather: " + g.msg + "\n");
        return 1;
    };
    let d = json.parse(g.body);
    print(banner(kind));
    print(wxrep.render(d.val, days).trim());
    0
};

def banner(kind: str) -> str {
    "weather " + TAG + " -- " + kind + "\n"
    + "temperatures are served in whole degrees Celsius and converted to\n"
    + "Fahrenheit in integers (no float->long and no cast syntax exist)\n"
};

// The whole-location report, and the strongest form of the "never a
// partially-filled report" property: N+1 requests, every one of them
// collected into one string, and NOTHING printed unless all of them
// succeeded. A failure half way through prints one line on stderr and the
// exit code 1, with a clean stdout.
def report_all(port: long, days: long) -> long {
    let f = ask_local(port, false, "", "/v1/locations");
    if (!f.ok) {
        eputs("weather: " + errmsg(f) + "\n");
        return 1;
    };
    let d = json.parse(f.body);
    if (!d.ok) {
        eputs("weather: the location list is not JSON at byte " + tostring(d.at) + ": " + d.err + "\n");
        return 1;
    };
    if (json.str_of(d.val, "schema") != TAG) {
        eputs("weather: expected schema " + TAG + ", got \"" + json.str_of(d.val, "schema") + "\"" + "\n");
        return 1;
    };
    let rows = json.arr_of(d.val, "locations");
    let out = "";
    let i = 0;
    while (i < rows.length) {
        let slug = json.str_of(rows[i], "slug");
        let g = ask_local(port, false, "", "/v1/forecast?city=" + quote(slug));
        if (!g.ok) {
            eputs("weather: " + slug + ": " + errmsg(g) + "\n");
            return 1;
        };
        let h = need(g, "");
        if (!h.ok) {
            eputs("weather: " + slug + ": " + h.msg + "\n");
            return 1;
        };
        out += wxrep.render(json.parse(h.body).val, days);
        i = i + 1;
    };
    print(banner("local canned forecast over loopback HTTP (forked, ephemeral port)"));
    print(out.trim());
    0
};

def list(f: Fetch) -> long {
    if (!f.ok) {
        eputs("weather: " + errmsg(f) + "\n");
        return 1;
    };
    let d = json.parse(f.body);
    if (!d.ok) {
        eputs("weather: the body is not JSON at byte " + tostring(d.at) + ": " + d.err + "\n");
        return 1;
    };
    if (json.str_of(d.val, "schema") != TAG) {
        eputs("weather: expected schema " + TAG + ", got \"" + json.str_of(d.val, "schema") + "\"" + "\n");
        return 1;
    };
    let rows = json.arr_of(d.val, "locations");
    print("locations served by the local forecast service: " + tostring(rows.length) + "\n");
    print(wxrep.render_locations(d.val).trim());
    0
};

// ── leg 3: the live service ────────────────────────────────────────────

def live(city: str, days: long) -> long {
    let f = wxlive.fetch(city, days);
    if (!f.ok) {
        eputs("weather: " + f.msg + "\n");
        return 1;
    };
    let d = json.parse(f.body);
    print(banner("live open-meteo.com forecast (no API key is bundled; it may rate-limit)"));
    print(wxrep.render(d.val, days).trim());
    0
};

// ── the command line ────────────────────────────────────────────────────
//
// args is the frozen toolkit module, vendored byte-identical (see
// README.md); the flag table below is this example's own.
//
// `--help` and `-h` are deliberately NOT declared here. args only treats
// them as help when they are absent from the table -- a declared one is an
// ordinary option and would demand a value.
const OPTS: [args.Opt] = [
    { long: "check", short: "", kind: args.BOOL, help: "run the property checks and exit" },
    { long: "list", short: "l", kind: args.BOOL, help: "list the locations the service serves" },
    { long: "city", short: "c", kind: args.STR, help: "one location slug, e.g. reykjavik" },
    { long: "days", short: "d", kind: args.NUM, help: "forecast rows per location (default 4)" },
    { long: "tls", short: "", kind: args.BOOL, help: "serve and fetch over real TLS 1.3" },
    { long: "live", short: "", kind: args.BOOL, help: "the real open-meteo.com API (needs the internet)" },
    { long: "verbose", short: "v", kind: args.BOOL, help: "also report the service's exit status" }
];

def main() -> long {
    // args's usage layout is: the usage line, then `tail` appended to it,
    // then `desc`, then the option table. So the description goes in the
    // TAIL and starts with a newline, or it ends up glued to "usage:" and,
    // in `desc`, below the examples where it reads as part of them.
    args.init("weather", "", OPTS,
              "\nweather -- a weather client and renderer, hermetic by default\n"
            + "\nexamples:\n"
            + "  weather                      the report for every canned location\n"
            + "  weather --city nairobi       one location\n"
            + "  weather --city nairobi -d 2  two forecast rows\n"
            + "  weather --list               what the service serves\n"
            + "  weather --city nowhere       the 404 path (exit 1, no report)\n"
            + "  weather --city 'reyk javik'  the 400 path (exit 1, no report)\n"
            + "  weather --tls                the same report over TLS 1.3\n"
            + "  weather --live --city quito  the real open-meteo.com API\n"
            + "  weather --check              the property checks\n");
    args.parse_or_exit(argv());

    let days = 4;
    if (args.has("days")) {
        days = args.get_long("days", 4);
        if (days < 1 || days > 4) {
            eputs("weather: --days must be 1 to 4 (the canned forecast holds four rows)" + "\n");
            return 2;
        };
    };
    let city = args.get_str("city", "");
    let verbose = args.has("verbose");

    // `--city` with an empty value is a mistake worth naming, not a request
    // for the whole world.
    if (args.has("city") && city.length == 0) {
        eputs("weather: --city needs a location slug; --list shows them" + "\n");
        return 2;
    };

    if (args.has("check")) { return selftest.run_self(verbose) };

    if (args.has("live")) {
        if (city.length == 0) {
            eputs("weather: --live needs --city NAME (open-meteo.com has no canned set)" + "\n");
            return 2;
        };
        return live(city, days);
    };

    let s = serve_local();
    let code = 0;
    let tls = args.has("tls");
    let srv = 0;
    let srv_port = 0;
    let pem = "";
    if (tls) {
        let t = wxlive.start_tls();
        if (!t.ok) {
            stop(s);
            eputs("weather: " + t.msg + "\n");
            return 3;
        };
        srv_port = t.port;
        pem = t.pem;
        srv = t.pid;
    };
    // The TLS leg talks to openssl s_server, not to the forked plain
    // service; `tport` is which port this run's requests go to.
    let tport = tls ? srv_port : s.port;

    // s_server can only serve the bytes that were piped into it, so the TLS
    // leg always answers with the Reykjavik forecast document. Saying so is
    // better than quietly ignoring --city, and better than printing an empty
    // location table read out of a forecast.
    if (tls && args.has("list")) {
        syscall(62, srv, 15);
        stop(s);
        eputs("weather: --list needs the plain-HTTP leg; the TLS leg serves one "
            + "fixed document (Reykjavik), so there is no location list to show\n");
        return 3;
    };

    // One request, one Fetch, one text() read. The leg decides only how the
    // request is made: https with the run's own certificate as the only
    // anchor, or plain http.
    if (args.has("list")) {
        code = list(ask_local(tport, false, pem, "/v1/locations"));
    } else if (tls) {
        if (city.length > 0 && wxdata.ascii_lower(city) != "reykjavik") {
            eputs("weather: --tls serves a fixed document (Reykjavik), so --city "
                + city + " is not used on that leg; use the default leg for other cities\n");
        };
        code = show_all(ask_local(tport, tls, pem, "/v1/forecast"),
                        "local canned forecast over TLS 1.3 (openssl s_server, "
                        + "certificate generated and pinned by this run)",
                        days);
    } else if (city.length > 0) {
        code = show(ask_local(s.port, false, pem,
                              "/v1/forecast?city=" + quote(wxdata.ascii_lower(city))), days);
    } else {
        code = report_all(s.port, days);
    };

    if (tls) { syscall(62, srv, 15) };
    let st = stop(s);
    if (verbose) {
        eputs("local service exited " + tostring(st) + " (143 = SIGTERM)" + "\n");
    };
    code
};

def ask_local(port: long, tls: bool, pem: str, target: str) -> Fetch {
    if (tls) { fetch_pinned("https://127.0.0.1:" + tostring(port) + target, pem) }
    else { fetch_plain("http://127.0.0.1:" + tostring(port) + target) }
};

// A city typed on the command line reaches the service as a query value, so
// it is percent-encoded first. Anything outside the unreserved set becomes
// %XX -- which is what turns `--city "reyk javik"` into a real 400 rather
// than a request the service cannot even parse.
def quote(s: str) -> str { wxfmt.pct(s) };

let rc = main();
exit(rc);
