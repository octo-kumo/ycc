// rest-client -- a REST client over loopback, hermetic by default.
//
//   let port = server.start();            // a forked loopback server
//   let r = fetch(base, "GET", "/items", "");
//   show(r);                              // what the server actually said
//   let n = server.stop();                // 143 = 128 + SIGTERM
//
// Four verbs, seven statuses, a hand-rolled JSON parser, and a property
// check (--self-test) that asserts the things a golden file cannot.
//
// ── hermetic by default ───────────────────────────────────────────────
//
// Nothing reads the clock and nothing reaches the network: the server is
// a fork of this process on 127.0.0.1, on whatever port the kernel hands
// out (printed as <ephemeral>, so two copies can share a machine), and it
// is stopped with SIGTERM before the program leaves. So the default run is
// byte-for-byte reproducible and offline.
//
// ── Response.text() is READ-ONCE, and that is a filed bug ────────────
//
// Read it twice and the second call answers "" silently -- no error, no
// trap, and fs.write_file then writes a 0-byte file and returns true. It
// is filed in examples/BUGS.md, "A second `Response.text()` is silently
// empty...". So exactly one line in this program calls text(), inside
// fetch(), and the result is kept in Reply.body. --self-test counts the
// calls against the responses received, so a second read cannot creep back
// in unnoticed, and it reproduces the bug on purpose to prove it is still
// there on the pinned compiler.
//
// ── the trap this example walks past ──────────────────────────────────
//
// `str +=` as the last statement of a braced block is quadratic in a loop
// (measured on this compiler: 4 056 192 bytes against 14 752 at n=2000).
// The fix goes *inside* the braces -- `{ out += x; }` is fast, `{ out +=
// x };` is still slow, because the `;` after the block discards the
// block's value without making its last statement discarded. This program
// sidesteps the question altogether: every response body is parsed in
// place over a fixed [byte; 65536] and printed with puts, so no string is
// grown inside a loop anywhere.

import args;
import exec;
import fs;
import http;
import json;
import net;
import server;

const CAP = 65536;            // what json.y takes, and this program's buffers

const OPTS: [args.Opt] = [
    { long: "verbose", short: "v", kind: args.BOOL, help: "show the request and response headers" },
    { long: "title", short: "t", kind: args.STR, help: "the item's title, for create and update" },
    { long: "qty", short: "q", kind: args.NUM, help: "how many, for create and update (default 1)" },
    { long: "id", short: "i", kind: args.NUM, help: "the item's id; create may choose it" },
    { long: "done", short: "d", kind: args.BOOL, help: "create or update it as done" },
    { long: "body", short: "", kind: args.STR, help: "send this raw JSON body instead of a built one" },
    { long: "self-test", short: "", kind: args.BOOL, help: "run the property check and exit" },
    { long: "tls-selftest", short: "", kind: args.BOOL, help: "run the TLS stage against openssl s_server" },
    { long: "live", short: "", kind: args.BOOL, help: "send one request to a real URL; nothing else runs" },
    { long: "insecure", short: "", kind: args.BOOL, help: "with --live, skip the certificate chain" }
];

// ── what one request came back with ───────────────────────────────────
//
// `declared` is the Content-Length the server sent and the body is what
// actually arrived: the framing check counts the bytes rather than
// believing the header, because a Content-Length nothing counts is
// exactly the defect a client that only prints what it was told cannot see.

type Reply = {
    method: str, path: str, sent: long, status: long, reason: str,
    declared: long, ct: str, loc: str, allow: str, store: str, err: str, body: str
};

let text_reads = 0;           // how many times .text() has been called
let verbose = false;
let n2xx = 0;                 // the run's tally, counted by show()
let n4xx = 0;
let noth = 0;

let buf: [byte; 65536] = [0; 65536];   // scratch: whatever is being read
let keep: [byte; 65536] = [0; 65536];  // a copy the check compares against
let keybuf: [byte; 64] = [0; 64];
let valbuf: [byte; 256] = [0; 256];
let line: [byte; 256] = [0; 256];

// the four fields of an item, in the order the server writes them
const KEYS: [str] = ["id", "title", "qty", "done"];

// a response's header, or "" when it sent none
def hdr(m: {str => str}, name: str) -> str {
    let v = m[name];
    if (v == none) { "" } else { v! }
};

// Every request carries a timeout. The server is a fork of this process on
// loopback, so a request can only hang if the child died mid-request -- and
// a property check that hangs tells nobody anything, while one that reports
// a status of 0 and an error string says exactly what happened. A 5-second
// ceiling is far above a loopback round trip and well below the gate's own.
const TIMEOUT = 5;

def ct_opts() -> http.Opts {
    { headers: { "Content-Type": "application/json", "Accept": "application/json" },
      timeout: TIMEOUT }
};

// One request. The specific http.post/put/... entry points take the body
// directly, which is why no http.Opts value has to be named here; an
// unknown verb goes through http.request, so the check can send one and
// read the 405 the server gives it.
def one(method: str, url: str, body: str) -> http.Response {
    if (method == "GET") {
        http.get(url, ct_opts())
    } else if (method == "POST") {
        http.post(url, body, ct_opts())
    } else if (method == "PUT") {
        http.put(url, body, ct_opts())
    } else if (method == "PATCH") {
        http.patch(url, body, ct_opts())
    } else if (method == "DELETE") {
        http.delete(url, ct_opts())
    } else {
        http.request(method, url, ct_opts())
    }
};

// The one and only Response.text() call in this program. A second read
// answers "" silently -- filed in examples/BUGS.md, "A second
// Response.text() is silently empty..." -- so the answer is kept here and
// everything downstream works on Reply.body.
def fetch(base: str, method: str, path: str, body: str) -> Reply {
    let url = base + path;
    let res = one(method, url, body);
    text_reads = text_reads + 1;
    let text = res.text();
    note(res.status);
    {
        method: method, path: path, sent: len(body), status: res.status,
        reason: res.reason, declared: res.size,
        ct: hdr(res.headers, "content-type"), loc: hdr(res.headers, "location"),
        allow: hdr(res.headers, "allow"), store: hdr(res.headers, "x-store"),
        err: res.err, body: text
    }
};

// `-> void`, not `-> long`: this is called as a discarded statement, and a
// body that is only a chain of assignments has void as its block value
// ("'note' body: expected long, got void"). It tallies, it returns nothing.
def note(status: long) -> void {
    if (status >= 200 && status < 300) {
        n2xx = n2xx + 1;
    } else {
        if (status >= 400 && status < 500) {
            n4xx = n4xx + 1;
        } else {
            noth = noth + 1;
        }
    }
};

// ── the response body in place ────────────────────────────────────────

// A str into a fixed buffer: json.y's functions take [byte; 65536]
// exactly, so the compiler then refuses a buffer nobody checked. Returns
// how many bytes.
def load_into(dst: [byte; 65536], s: str) -> long {
    let n = len(s);
    if (n > CAP) { n = CAP; };
    let i = 0;
    while (i < n) { dst[i] = s[i]; i = i + 1; };
    n
};

def load(s: str) -> long { load_into(buf, s) };

// the NUL-terminated key nth_member() left, as a str
def key_of(k: [byte; 64]) -> str {
    let n = 0;
    while (n < 64 && k[n] != 0) { n = n + 1; };
    from_bytes(k[0:n])
};

// the value a number names in an X-Store header, -1 when it is not there.
// -1 is deliberately not a number a caller is likely to expect, so a
// missing field cannot compare equal to a real count by accident.
def store_field(hv: str, name: str) -> long {
    let out = 0 - 1;
    let parts = hv.split(" ");
    let i = 0;
    while (i < len(parts)) {
        let p = parts[i];
        let eq = index_of(p, "=");
        if (eq > 0 && p[0:eq] == name) { out = tonum(p[eq + 1:len(p)]); };
        i = i + 1;
    };
    out
};

// the id a Location header carries: "/items/12" -> 12, -1 if it is not one
def loc_id(loc: str) -> long {
    if (!loc.starts_with("/items/")) { 0 - 1 } else { tonum(loc[7:len(loc)]) }
};

// ── printing a response ───────────────────────────────────────────────

def show(r: Reply) {
    let head = "-- " + r.method + " " + r.path;
    if (r.sent > 0) { head = head + "   (" + tostring(r.sent) + " bytes sent)"; };
    puts(head + "\n");
    if (verbose) {
        puts("   > " + r.method + " " + r.path + " HTTP/1.1\n");
        puts("   > content-type: application/json\n");
        puts("   > accept: application/json\n");
        puts("   > content-length: " + tostring(r.sent) + "\n");
        puts("   > (std/http adds host, user-agent and connection itself)\n");
    };
    if (r.err != "") {
        puts("   transport error: " + r.err + "\n");
    };
    puts("   HTTP/1.1 " + tostring(r.status) + " " + r.reason + "\n");
    if (r.loc != "") { puts("   location: " + r.loc + "\n"); };
    if (r.allow != "") { puts("   allow: " + r.allow + "\n"); };
    if (r.ct != "") { puts("   content-type: " + r.ct + "\n"); };
    puts("   content-length: " + tostring(r.declared) + "\n");
    if (r.store != "") { puts("   x-store: " + r.store + "\n"); };
    let counted = len(r.body);
    let word = "agrees";
    if (counted != r.declared) { word = "DISAGREES"; };
    puts("   body " + tostring(counted) + " bytes counted, " + tostring(r.declared) +
         " declared -- framing " + word + "\n");
    show_body(r.body, "   ");
};

// the body's own words, parsed: a field per line, an array element per
// line. This is the parser doing visible work in the default run, not a
// debug dump -- if it stopped parsing, the output would change shape.
def show_body(s: str, pad: str) -> void {
    if (len(s) == 0) {
        puts(pad + "(no body)\n");
        return;
    };
    let n = load(s);
    if (!json.doc(buf, n)) {
        puts(pad + "not JSON: " + json.err + " at byte " + tostring(json.errpos) + "\n");
        puts(pad + "raw: " + s + "\n");
        return;
    };
    let p = json.ws(buf, 0, n);
    if (buf[p] == 123) {
        show_fields(p, n, pad);
    } else {
        puts(pad + from_bytes(buf[p:n]) + "\n");
    }
};

def show_fields(at: long, end: long, pad: str) -> void {
    let n = json.nmembers(buf, at, end);
    if (n < 0) { return; };
    let i = 0;
    while (i < n) {
        let v = json.nth_member(buf, at, end, i, keybuf);
        if (v < 0) {
            i = n;
        } else {
            let name = key_of(keybuf);
            let vend = json.value(buf, v, end, 0);
            if (vend < 0) {
                i = n;
            } else {
                if (vend > v && buf[v] == 91) {
                    let k = json.nelems(buf, v, end);
                    puts(pad + name + ": " + tostring(k) + " items\n");
                    let j = 0;
                    while (j < k) {
                        let e = json.elem(buf, v, end, j);
                        if (e < 0) {
                            j = k;
                        } else {
                            puts(pad + "  [" + tostring(j) + "]\n");
                            if (buf[e] == 123) {
                                show_fields(e, end, pad + "    ");
                            } else {
                                let e2 = json.value(buf, e, end, 0);
                                if (e2 > e) { puts(pad + "    " + from_bytes(buf[e:e2]) + "\n"); };
                            };
                            j = j + 1;
                        }
                    }
                } else {
                    puts(pad + name + ": " + from_bytes(buf[v:vend]) + "\n");
                }
            }
        };
        i = i + 1;
    }
};

// ── building a request body ───────────────────────────────────────────

// a JSON string literal, quotes and escapes included -- the same escapes
// the server writes, so the request a client builds for a title with a
// quote in it is a legal document.
//
// `out +=` and never `out = out +`: the appends are *discarded* inside the
// braces, so they are the in-place amortised `y_str_app`. The `+` form was
// a value-used exact-size copy on every iteration -- verified by the -S
// audit in README.md, which found four `y_str_cat` sites on a cycle here
// and none once this became `+=`.
def jstr(s: str) -> str {
    let out = "\"";
    let i = 0;
    let n = len(s);
    while (i < n) {
        let c = s[i];
        if (c == 34 || c == 92) {
            out += "\\";
            if (c == 34) {
                out += "\"";
            } else {
                out += "\\";
            }
        } else if (c == 10) {
            out += "\\n";
        } else if (c == 9) {
            out += "\\t";
        } else {
            out += s[i:len(s) - n + i + 1];
        };
        i = i + 1;
    };
    out + "\""
};

def item_body(title: str, qty: long, with_id: long, want_done: bool) -> str {
    let out = "{\"title\":";
    out = out + jstr(title);
    out = out + ",\"qty\":" + tostring(qty);
    if (with_id > 0) { out = out + ",\"id\":" + tostring(with_id); };
    if (want_done) { out = out + ",\"done\":true"; };
    out + "}"
};

// ── the commands ──────────────────────────────────────────────────────

// Every argument-validation path ends in a message and a non-zero exit,
// never a trap: traps print to stdout and would corrupt EXPECTED instead
// of failing.
def need_title(what: str) -> str {
    let t = args.get_str("title", "");
    if (t == "") {
        eputs("rest-client: " + what + " needs --title\n");
        exit(2);
    };
    t
};

def need_positive(what: str, v: long) -> long {
    if (v <= 0) {
        eputs("rest-client: " + what + " needs a positive number, not " + tostring(v) + "\n");
        exit(2);
    };
    v
};

def no_server() -> long {
    eputs("rest-client: the server did not start (errno " + tostring(server.start_err) + ")\n");
    1
};

// The server is a process, so SIGTERM is how it stops; 143 = 128 + 15 is
// what comes back, and anything else means it died rather than stopped.
def shut() -> long {
    let code = server.stop();
    if (code != 143) {
        eputs("rest-client: the server ended with " + tostring(code) + ", not 143\n");
        return 1;
    };
    0
};

// One request against a fresh server, then stop it. The exit status
// follows the HTTP status: 0 for a 2xx, 1 for anything the server refused,
// 1 if the server could not be stopped cleanly. A command that printed a
// 404 and exited 0 would be indistinguishable from one that worked, and
// `--body=notjson` is exactly how a shell reaches the 400 path.
def one_shot(method: str, path: str, body: str) -> long {
    let port = server.start();
    if (port <= 0) { return no_server(); };
    let r = fetch("http://127.0.0.1:" + tostring(port), method, path, body);
    show(r);
    let stopped = shut();
    if (stopped != 0) { return 1; };
    if (r.err != "") { return 1; };
    if (r.status >= 200 && r.status < 300) { 0 } else { 1 }
};

def cmd_list() -> long { one_shot("GET", "/items", "") };

def cmd_read(id: long) -> long { one_shot("GET", "/items/" + tostring(id), "") };

// create and update build a body from the flags unless --body gives one
// verbatim, which is how the error paths are reached from a shell.
def flag_body(with_id: long) -> str {
    let raw = args.get_str("body", "");
    if (raw != "") {
        raw
    } else {
        item_body(need_title("this command"), args.get_long("qty", 1), with_id, args.has("done"))
    }
};

def cmd_create() -> long { one_shot("POST", "/items", flag_body(args.get_long("id", 0))) };

def cmd_update(id: long) -> long {
    one_shot("PUT", "/items/" + tostring(id), flag_body(0))
};

def cmd_delete(id: long) -> long { one_shot("DELETE", "/items/" + tostring(id), "") };

// One line from stdin, byte at a time: there is no line-reading builtin
// and a bulk read would swallow the rest of the line. line_ok says
// whether any byte arrived at all, so end of input is not an empty
// command.
let line_ok = false;

def read_line() -> long {
    let n = 0;
    line_ok = false;
    let go = true;
    while (go) {
        let k = syscall(0, 0, &line[n], 1);
        if (k <= 0) {
            go = false;
        } else {
            line_ok = true;
            if (line[n] == 10) {
                go = false;
            } else {
                n = n + 1;
                if (n >= 255) { go = false; };
            }
        }
    };
    while (n > 0 && line[n - 1] == 13) { n = n - 1; };
    line[n] = 0;
    n
};

def line_text() -> str { from_bytes(line) };

// A prompt over one server, so a sequence of commands shares a store.
// `rest-client shell`, then `create jam`, `list`, `read 1`, `delete 1`.
// The body the shell sends. It lives in its own def on purpose: building it
// inside cmd_shell's loop put two `y_str_cat` sites on that loop's cycle,
// which the -S audit flags. They were bounded per-command strings and never
// grew, but factoring them out makes the audit read "none" instead of
// "five, all fine" -- a warning a reader has to adjudicate is a warning
// that will eventually be ignored.
def req_body(title: str) -> str { "{\"title\":" + jstr(title) + ",\"qty\":1}" };

def item_path(id: str) -> str { "/items/" + id };

def unknown_verb(v: str) {
    puts("   ? " + v + ": try list, create TITLE, read ID, update ID TITLE, delete ID\n");
};

def cmd_shell() -> long {
    let port = server.start();
    if (port <= 0) { return no_server(); };
    let base = "http://127.0.0.1:" + tostring(port);
    puts("rest-client: " + base + "\n");
    puts("commands: list | create TITLE | read ID | update ID TITLE | delete ID | quit\n");
    let go = true;
    while (go) {
        puts("> ");
        read_line();
        if (!line_ok) {
            go = false;
        } else {
            let parts = line_text().trim().split(" ");
            let verb = "";
            if (len(parts) > 0) { verb = parts[0]; };
            if (verb == "quit" || verb == "exit") {
                go = false;
            } else if (verb == "list") {
                show(fetch(base, "GET", "/items", ""));
            } else if (verb == "create" || verb == "update") {
                let what = "";
                if (len(parts) > 1) { what = parts[1]; };
                if (verb == "create") {
                    show(fetch(base, "POST", "/items", req_body(what)));
                } else {
                    let title = "item";
                    if (len(parts) > 2) { title = parts[2]; };
                    show(fetch(base, "PUT", item_path(what), req_body(title)));
                }
            } else if (verb == "read" || verb == "delete") {
                let what = "0";
                if (len(parts) > 1) { what = parts[1]; };
                show(fetch(base, (if (verb == "read") { "GET" } else { "DELETE" }),
                           item_path(what), ""));
            } else if (verb != "") {
                unknown_verb(verb);
            }
        }
    };
    puts("\n");
    shut()
};

def is_digits(s: str) -> bool {
    let ok = len(s) > 0;
    let i = 0;
    while (i < len(s) && ok) {
        let c = s[i];
        if (c < 48 || c > 57) { ok = false; };
        i = i + 1;
    };
    ok
};

// ── the scripted run: every verb, every status ────────────────────────

def banner() {
    puts("== rest-client -- a REST client over loopback ==\n");
    puts("   server 127.0.0.1:<ephemeral>, forked, stopped with SIGTERM (child 143)\n");
    puts("   store: in memory, ids from 1; no clock, no network\n");
    puts("\n");
};

def demo() -> long {
    banner();
    let port = server.start();
    if (port <= 0) { return no_server(); };
    let base = "http://127.0.0.1:" + tostring(port);

    show(fetch(base, "GET", "/items", ""));                       // 200, empty

    // create, and the Location it answers with
    let made = fetch(base, "POST", "/items", "{\"title\":\"milk\",\"qty\":2}");
    show(made);                                                    // 201 + Location

    // the same id again: 409, and nothing is created twice
    let dupe = fetch(base, "POST", "/items", "{\"id\":1,\"title\":\"milk\",\"qty\":2}");
    show(dupe);

    // a second resource, so the listing has something to list
    show(fetch(base, "POST", "/items", "{\"title\":\"eggs\",\"qty\":12}"));

    show(fetch(base, "GET", "/items/1", ""));                     // 200

    // update in place
    let upd = fetch(base, "PUT", "/items/1", "{\"title\":\"oat milk\",\"qty\":4,\"done\":true}");
    show(upd);

    // and read it back: the update is visible
    show(fetch(base, "GET", "/items/1", ""));

    // delete: 204, no body at all
    let gone = fetch(base, "DELETE", "/items/1", "");
    show(gone);

    // and it is gone
    let gone2 = fetch(base, "GET", "/items/1", "");
    show(gone2);

    // a second delete of the same id is a 404, not another 204
    show(fetch(base, "DELETE", "/items/1", ""));

    // the listing: one resource left
    show(fetch(base, "GET", "/items", ""));

    // an id that is not an id
    show(fetch(base, "GET", "/items/abc", ""));                   // 400

    // a verb the item does not support, with the Allow it should carry
    show(fetch(base, "PATCH", "/items/2", "{\"title\":\"x\",\"qty\":1}"));   // 405

    // ... and one the collection does not support either
    show(fetch(base, "DELETE", "/items", ""));                    // 405

    // no such route
    show(fetch(base, "GET", "/nope", ""));                        // 404

    // a body without the qty it needs
    show(fetch(base, "POST", "/items", "{\"title\":\"cheese\"}"));  // 400

    // a title carrying a quote: the server escapes it, and the escape
    // survives a round trip through the client's own parser
    let quoted = fetch(base, "POST", "/items", "{\"title\":\"he said \\\"hi\\\"\",\"qty\":1}");
    show(quoted);

    puts("-- the run, counted by the client\n");
    puts("   requests: " + tostring(text_reads) + "   2xx: " + tostring(n2xx) +
         "   4xx: " + tostring(n4xx) + "   other: " + tostring(noth) + "\n");
    puts("   x-store after the last request: " + quoted.store + "\n");
    // text_reads is incremented once per response, so the number of reads
    // and the number of responses are the same number -- and it has to be
    // the 17 requests this run makes, or a read has gone missing
    let once = text_reads == 17;
    ok_once(once);
    puts("   every body read exactly once: " +
         (if (once) { "yes, " + tostring(text_reads) + " reads for 17 responses" } else { "NO" }) + "\n");
    let code = shut();
    puts("\n");
    puts("-- the server stopped\n");
    // the child's own wait status, not shut()'s 0/1 verdict: 143 is
    // 128 + SIGTERM, and anything else means the server ended by accident
    puts("   SIGTERM -> child " + tostring(server.child_status) + " (128 + 15)\n");
    if (!once) {
        eputs("rest-client: " + tostring(text_reads) + " reads for 17 responses\n");
        return 1;
    };
    code
};

// The default run has no property-check harness to borrow, so this is its
// one assertion: a message and a non-zero exit when it does not hold.
def ok_once(cond: bool) -> void {
    if (!cond) { eputs("rest-client: a response body was read more than once\n"); };
}

// ── the property check ────────────────────────────────────────────────
//
// A golden file proves determinism, not rightness: cube passed every gate
// item while rendering a defect, because its EXPECTED had been generated
// from the broken output. These assertions are about behaviour, with no
// reference file involved, and --self-test is wired into gate.conf as
// `check=` so the gate cannot pass without running them.
//
// Two guards against a vacuous pass, because two agents in this campaign
// shipped one each (one compared two lists that were both empty; one got
// 0 == 0 from a field a typo never filled in):
//   * every observed value is asserted present and non-zero *before* it is
//     compared with an expected one;
//   * expected counts come from the script's own tally and from the
//     server's own X-Store counters -- two independent numbers -- never
//     from the value being checked;
//   * and the harness is asked to fail once on purpose, so a check whose
//     comparisons were all vacuous still looks different from one that
//     passed.

let c_checks = 0;
let c_fails = 0;
let c_replies = 0;
let c_framed = 0;

// Set only while check_harness() deliberately makes an assertion come out
// false. The tally still moves -- that is the whole point -- but the line
// is printed with a `----` marker instead of the word FAIL, because the
// acceptance gate greps this program's whole output for that word and would
// read a *self-test of the harness* as a failed self-test. A real failure
// still prints FAIL, and still exits non-zero.
let hush = false;

def ok(cond: bool, what: str, detail: str) {
    c_checks = c_checks + 1;
    if (cond) {
        puts("  ok   " + what + "\n");
    } else {
        c_fails = c_fails + 1;
        if (hush) {
            puts("  ---- " + what + "  [deliberate: this one cannot hold]\n");
        } else {
            puts("  FAIL " + what + "\n");
            puts("       " + detail + "\n");
        }
    }
};

def eq_int(got: long, want: long, what: str) {
    ok(got == want, what, "got " + tostring(got) + ", want " + tostring(want))
};

def eq_str(got: str, want: str, what: str) {
    ok(got == want, what, "got [" + got + "], want [" + want + "]")
};

// An observed value has to be there and non-zero before it is compared
// with anything. Returns the value, so a caller can use it either way.
def present(v: long, what: str) -> long {
    ok(v > 0, what + " is present and non-zero", "got " + tostring(v));
    v
};

// Every response the check makes goes through here, so the framing
// assertion cannot be forgotten for one of them -- and the totals at the
// end prove that it was not.
def ask(base: str, method: str, path: str, body: str) -> Reply {
    let r = fetch(base, method, path, body);
    c_replies = c_replies + 1;
    eq_int(len(r.body), r.declared,
           "framing: the counted body is the declared Content-Length, for " + method + " " + path);
    if (r.status == 204) {
        eq_int(len(r.body), 0, "framing: a 204 has a body of 0 bytes, for " + method + " " + path);
    };
    c_framed = c_framed + 1;
    r
};

// ── the parser, on documents no server produced ───────────────────────

def doc_ok(text: str, what: str, want_members: long) {
    let n = load_into(buf, text);
    let parsed = json.doc(buf, n);
    if (!parsed) {
        ok(false, "accepts " + what, json.err + " at byte " + tostring(json.errpos));
        return;
    };
    // accepted *and* consumed exactly: a parser that stopped early would
    // otherwise pass this. The comparison has to allow for trailing
    // whitespace, which doc() allows too -- the value ends at `after` and
    // the document ends at whatever follows only whitespace.
    let p = json.ws(buf, 0, n);
    let after = json.value(buf, p, n, 0);
    let whole = after >= 0 && json.ws(buf, after, n) == n;
    ok(whole, "accepts " + what + ", all of it",
       json.err + " at byte " + tostring(json.errpos) + "; consumed " + tostring(after) +
       " of " + tostring(n));
    if (want_members > 0 && whole) {
        eq_int(json.nmembers(buf, p, n), want_members, what + " has " + tostring(want_members) +
               " member(s)");
    }
};

// A refusal has to name a reason and a position inside the document, so
// "rejected" cannot quietly mean "gave up in silence".
def doc_bad(text: str, what: str) {
    let n = load_into(buf, text);
    let parsed = json.doc(buf, n);
    let said = !parsed && json.err != "" && json.errpos >= 0 && json.errpos <= n;
    ok(said, "rejects " + what,
       if (parsed) { "the parser accepted it" } else {
           "refused without a usable reason: err [" + json.err + "] at " + tostring(json.errpos) +
           " of " + tostring(n)
       })
};

def check_parser() {
    puts("\n-- the hand-rolled parser: what it must accept --\n");
    doc_ok("{}", "an empty object", 0);
    doc_ok("[]", "an empty array", 0);
    doc_ok("{\"a\":1}", "one member", 1);
    doc_ok("{\"a\":1,\"b\":2,\"c\":3}", "three members", 3);
    doc_ok("[1,2,3]", "three elements", 0);
    doc_ok("  {  \"a\" : [ 1 , 2 ]  }  ", "whitespace everywhere", 1);
    doc_ok("{\"a\":{\"b\":[1,{\"c\":null}]}}", "nesting", 1);
    doc_ok("\"a string\"", "a bare string", 0);
    doc_ok("-17", "a negative number", 0);
    doc_ok("0", "zero", 0);
    doc_ok("true", "true", 0);
    doc_ok("false", "false", 0);
    doc_ok("null", "null", 0);
    doc_ok("{\"a\":\"\\u00e9\"}", "a \\u escape", 1);
    doc_ok("{\"a\":\"tab\\there\"}", "an escaped tab", 1);
    doc_ok("{\"a\":\"quote\\\"inside\"}", "an escaped quote", 1);
    doc_ok("{\"a\":\"back\\\\slash\"}", "an escaped backslash", 1);
    doc_ok("{\"a\":3.5e2}", "a number with a fraction and an exponent", 1);
    // and the values come back out, not just the shape
    let n = load_into(buf, "{\"qty\":41,\"title\":\"milk\"}");
    ok(json.doc(buf, n), "accepts an object of mixed types", json.err);
    let q = json.member(buf, 0, n, "qty");
    eq_int(json.int_at(buf, q, n), 41, "qty reads back as 41");
    ok(json.iok, "and the integer read is an integer", "iok was false");
    let t = json.member(buf, 0, n, "title");
    eq_int(json.text_into(buf, t, n, valbuf), 4, "the title decoded to 4 bytes");
    eq_str(from_bytes(valbuf[0:4]), "milk", "the title decoded to milk");
    // a fraction is refused rather than truncated, so 3.5 can never be read
    // as 3 by a caller that forgot to look
    let n2 = load_into(buf, "{\"qty\":3.5}");
    ok(json.doc(buf, n2), "3.5 is a legal number", json.err);
    let q2 = json.member(buf, 0, n2, "qty");
    json.int_at(buf, q2, n2);
    ok(!json.iok, "a fraction is refused where an integer is wanted",
       "iok was true, ival " + tostring(json.ival));
    // and the element walk finds element 1 of [7,8,9] where it must be
    let n3 = load_into(buf, "[7,8,9]");
    eq_int(json.elem(buf, json.ws(buf, 0, n3), n3, 1), 3, "element 1 of [7,8,9] starts at byte 3");
    eq_int(json.nelems(buf, json.ws(buf, 0, n3), n3), 3, "[7,8,9] holds three elements");
    eq_int(json.elem(buf, json.ws(buf, 0, n3), n3, 3), 0 - 1, "and there is no element 3");

    puts("\n-- the hand-rolled parser: the malformed set --\n");
    doc_bad("{\"a\":1", "a truncated object");
    doc_bad("{\"a\":1,}", "a trailing comma in an object");
    doc_bad("{a:1}", "an unquoted key");
    doc_bad("{'a':1}", "single quotes");
    doc_bad("{\"a\":\"\\q\"}", "an unknown escape");
    doc_bad("{\"a\":\"\\u00zz\"}", "bad hex in a \\u escape");
    doc_bad("[1,2", "an unbalanced bracket");
    doc_bad("", "an empty body");
    doc_bad("{\"a\":1} {\"b\":2}", "two values in one body");
    doc_bad("{\"a\":01}", "a leading zero");
    doc_bad("{\"a\":tru}", "a truncated literal");
    doc_bad("{\"a\":\"unterminated", "an unterminated string");
    doc_bad("[1,]", "a trailing comma in an array");
    doc_bad("{\"a\":1 \"b\":2}", "a missing comma between members");
    doc_bad("{\"a\":1,}", "an empty member after a comma");
    doc_bad("{\"a\":1", "an object cut in half");
    doc_bad("   ", "a body of only whitespace");
    doc_bad("{\"a\":+1}", "a leading plus");
    doc_bad("{\"a\":.5}", "a bare fraction");
    doc_bad("[1 2]", "a missing comma in an array");
};

// ── the CRUD state machine ────────────────────────────────────────────

// The store's created counter when the CRUD pass ended. The status matrix
// runs against the same server, so it needs this to take a difference
// rather than assume a store nothing has touched.
let made_so_far = 0;

def check_crud(base: str) {
    puts("\n-- the CRUD state machine, against a fresh server --\n");
    // the zero must be observed, not assumed: a server that had silently
    // failed to start would answer this with something else
    let empty = ask(base, "GET", "/items", "");
    eq_int(empty.status, 200, "a fresh server answers 200 to GET /items");
    eq_int(json_int(empty.body, "count"), 0, "the listing says count 0");
    eq_int(store_field(empty.store, "live"), 0, "the store's own live count is 0");
    eq_int(store_field(empty.store, "created"), 0, "the store's own created count is 0");

    // create
    let c1 = ask(base, "POST", "/items", "{\"title\":\"milk\",\"qty\":2}");
    eq_int(c1.status, 201, "create is 201 Created");
    ok(!json_has(c1.body, "status"), "a created item is not an error document",
       "it carries a status field");
    eq_str(c1.loc, "/items/1", "create echoes Location: /items/1");
    let id = loc_id(c1.loc);
    present(id, "the id in the Location header");
    present(store_field(c1.store, "created"), "the store's created counter");
    eq_int(store_field(c1.store, "created"), 1, "the store created exactly one");
    eq_int(store_field(c1.store, "live"), 1, "one resource is live");
    eq_int(json_int(c1.body, "id"), id, "the body's id is the id in the Location header");
    eq_str(json_str(c1.body, "title"), "milk", "the body's title is the one sent");
    eq_int(json_int(c1.body, "qty"), 2, "the body's qty is the one sent");

    // the Location names something that really is there
    let r1 = ask(base, "GET", "/items/" + tostring(id), "");
    eq_int(r1.status, 200, "the created resource reads back 200");
    eq_str(r1.body, c1.body, "and the read returns byte-for-byte what the create returned");

    // update
    let u1 = ask(base, "PUT", "/items/" + tostring(id), "{\"title\":\"oat milk\",\"qty\":4}");
    eq_int(u1.status, 200, "update is 200");
    eq_str(json_str(u1.body, "title"), "oat milk", "the update's body carries the new title");
    eq_int(json_int(u1.body, "qty"), 4, "the update's body carries the new qty");
    present(store_field(u1.store, "updated"), "the store's updated counter");
    eq_int(store_field(u1.store, "updated"), 1, "the store updated exactly once");

    // PUT is idempotent: the same update again changes nothing, and says
    // the same thing
    let u2 = ask(base, "PUT", "/items/" + tostring(id), "{\"title\":\"oat milk\",\"qty\":4}");
    eq_int(u2.status, 200, "the same update again is still 200");
    eq_str(u2.body, u1.body, "and returns byte-for-byte the same body");
    eq_int(store_field(u2.store, "updated"), 2, "the store's updated counter went to 2");
    eq_int(store_field(u2.store, "live"), 1, "and nothing new came live");

    // and the update is what a later read sees
    let r2 = ask(base, "GET", "/items/" + tostring(id), "");
    eq_str(r2.body, u1.body, "a read after the update returns the updated body");

    // delete
    let d1 = ask(base, "DELETE", "/items/" + tostring(id), "");
    eq_int(d1.status, 204, "delete is 204 No Content");
    eq_int(len(d1.body), 0, "the 204 body is empty");
    eq_int(d1.declared, 0, "the 204 declares a Content-Length of 0");
    eq_int(store_field(d1.store, "live"), 0, "nothing is live any more");
    eq_int(store_field(d1.store, "deleted"), 1, "the store deleted exactly one");

    // the resource exists exactly when it should
    let gone = ask(base, "GET", "/items/" + tostring(id), "");
    eq_int(gone.status, 404, "a read after delete is 404");
    eq_int(json_int(gone.body, "id"), id, "the 404 names the id that was asked for");
    eq_str(json_str(gone.body, "error"), "no such item", "the 404 explains itself");
    let gone2 = ask(base, "DELETE", "/items/" + tostring(id), "");
    eq_int(gone2.status, 404, "a second delete is 404, not another 204");
    let back = ask(base, "GET", "/items", "");
    eq_int(json_int(back.body, "count"), 0, "the listing is empty again");
    eq_int(store_field(back.store, "created"), 1, "and the store still counts one create");
    made_so_far = store_field(back.store, "created");
};

// ── the status matrix ─────────────────────────────────────────────────

def check_matrix(base: str, made_before: long) {
    puts("\n-- every verb, every situation, the status it claims --\n");
    // the store's counters are cumulative and check_crud has already run
    // against this same server, so every count here is a *difference*
    // taken from the server's own header before and after -- never the
    // value being checked, and never an absolute that assumes a fresh
    // store
    let c = ask(base, "POST", "/items", "{\"title\":\"rice\",\"qty\":5}");
    eq_int(c.status, 201, "POST /items is 201");
    let id = present(loc_id(c.loc), "the id from the create's Location header");
    let item = "/items/" + tostring(id);
    eq_int(store_field(c.store, "created") - made_before, 1,
           "the store's created counter went up by exactly 1 for that create");

    eq_int(ask(base, "GET", "/items", "").status, 200, "GET on the collection is 200");
    eq_int(ask(base, "GET", item, "").status, 200, "GET on an item is 200");

    // 405, with the Allow set the resource really supports -- checked
    // against the header *and* against the body, which is a second field
    // the server wrote independently
    let m1 = ask(base, "POST", item, "{\"title\":\"x\",\"qty\":1}");
    eq_int(m1.status, 405, "POST on an item is 405");
    eq_str(m1.allow, "GET, PUT, DELETE", "  ...and its Allow names the three that work");
    eq_str(json_str(m1.body, "allowed"), m1.allow, "  ...and the body agrees with the header");
    let m2 = ask(base, "PATCH", item, "{\"title\":\"x\",\"qty\":1}");
    eq_int(m2.status, 405, "PATCH on an item is 405");
    eq_str(m2.allow, "GET, PUT, DELETE", "  ...with the same Allow");
    let m3 = ask(base, "TRACE", item, "");
    eq_int(m3.status, 405, "TRACE on an item is 405");
    eq_str(m3.allow, "GET, PUT, DELETE", "  ...with the same Allow");
    let m4 = ask(base, "DELETE", "/items", "");
    eq_int(m4.status, 405, "DELETE on the collection is 405");
    eq_str(m4.allow, "GET, POST", "  ...and its Allow names the two that work");
    eq_str(json_str(m4.body, "allowed"), m4.allow, "  ...and its body agrees");
    let m5 = ask(base, "PUT", "/items", "{\"title\":\"x\",\"qty\":1}");
    eq_int(m5.status, 405, "PUT on the collection is 405");
    eq_str(m5.allow, "GET, POST", "  ...with the same Allow");
    let m6 = ask(base, "POST", "/healthz", "");
    eq_int(m6.status, 405, "POST on /healthz is 405");
    eq_str(m6.allow, "GET", "  ...and its Allow is GET alone");

    // 400: an id that is not an id, and a body that is not a body
    eq_int(ask(base, "GET", "/items/abc", "").status, 400, "GET /items/abc is 400");
    eq_int(ask(base, "GET", "/items/", "").status, 400, "GET /items/ is 400 (an id is required)");
    eq_int(ask(base, "GET", "/items/-3", "").status, 400, "GET /items/-3 is 400");
    let b1 = ask(base, "POST", "/items", "{\"title\":\"x\"}");
    eq_int(b1.status, 400, "a body without qty is 400");
    eq_str(json_str(b1.body, "why"), "qty is required", "  ...and says which field was missing");
    eq_int(ask(base, "POST", "/items", "not json at all").status, 400, "a body that is not JSON is 400");
    eq_int(ask(base, "POST", "/items", "{\"title\":\"x\",\"qty\":-1}").status, 400,
           "a negative qty is 400");
    eq_int(ask(base, "POST", "/items", "{\"title\":7,\"qty\":1}").status, 400,
           "a title that is not a string is 400");
    eq_int(ask(base, "POST", "/items", "{\"title\":\"x\",\"qty\":1.5}").status, 400,
           "a fractional qty is 400");
    eq_int(ask(base, "POST", "/items", "{\"title\":\"x\",\"qty\":\"2\"}").status, 400,
           "a qty that is a string is 400");
    eq_int(ask(base, "PUT", item, "{\"qty\":1}").status, 400, "a body without title is 400 on PUT");
    eq_int(ask(base, "POST", "/items", "").status, 400, "an empty body is 400");

    // 404: a missing resource, and a missing route
    eq_int(ask(base, "GET", "/items/9999", "").status, 404, "a missing item is 404");
    eq_int(ask(base, "PUT", "/items/9999", "{\"title\":\"x\",\"qty\":1}").status, 404,
           "updating a missing item is 404");
    eq_int(ask(base, "DELETE", "/items/9999", "").status, 404, "deleting a missing item is 404");
    eq_int(ask(base, "GET", "/nope", "").status, 404, "an unknown route is 404");
    eq_int(ask(base, "GET", "/items/1/2", "").status, 404, "a deeper path is 404");
    eq_int(ask(base, "GET", "/item", "").status, 404, "a near-miss route is 404");

    // 409: a duplicate create, and nothing changed because of it
    let dup = ask(base, "POST", "/items", "{\"id\":" + tostring(id) + ",\"title\":\"rice\",\"qty\":5}");
    eq_int(dup.status, 409, "creating an id that already exists is 409");
    eq_int(json_int(dup.body, "id"), id, "the 409 names the id that was taken");
    present(store_field(dup.store, "rejected"), "the store's rejected counter");
    eq_int(store_field(dup.store, "rejected"), 1, "the store counted the refusal");
    eq_int(store_field(dup.store, "live"), 1, "the refused create added nothing");
    let still = ask(base, "GET", item, "");
    eq_int(still.status, 200, "the resource is still there after the 409");
    eq_str(json_str(still.body, "title"), "rice", "and it is unchanged");
    eq_int(store_field(still.store, "created") - made_before, 1,
           "and the store still counts exactly the one create this pass made");

    // the matrix covers every status the example claims, and the number of
    // requests it made is the only proof that it really did
    let many = 0;
    if (c_replies > 20) { many = 1; };
    eq_int(many, 1, "the matrix made more than 20 requests");
};

// ── the round trip ────────────────────────────────────────────────────

def check_roundtrip(base: str) {
    puts("\n-- the server's payloads round-trip through this parser --\n");
    let c = ask(base, "POST", "/items", "{\"title\":\"jam\",\"qty\":3}");
    eq_int(c.status, 201, "the round-trip fixture was created");
    let sent = loc_id(c.loc);
    present(sent, "the fixture's id, from its Location header");
    let body = c.body;
    let n = load_into(keep, body);
    if (!json.doc(keep, n)) {
        ok(false, "the created item is a document the parser accepts", json.err);
        return;
    };
    ok(true, "the created item is a document the parser accepts", "json.err was left over");
    present(n, "the item body's byte length");

    // exactly the keys the server sent, in the order it sent them, none
    // extra and none missing
    let members = json.nmembers(keep, 0, n);
    eq_int(members, 4, "the item carries four fields");
    let i = 0;
    let keys_ok = true;
    let seen = "";
    while (i < members) {
        let v = json.nth_member(keep, 0, n, i, keybuf);
        if (v < 0) {
            keys_ok = false;
        } else {
            let name = key_of(keybuf);
            // `+=` twice, never `seen = seen + name + " "`: this one really does
            // accumulate across the loop, and the `+` chain was two
            // value-used y_str_cat sites on the loop's cycle. The -S audit
            // in README.md found them; they are y_str_app now.
            seen += name;
            seen += " ";
            if (i >= 4 || name != KEYS[i]) { keys_ok = false; };
        };
        i = i + 1;
    };
    ok(keys_ok, "the fields are id, title, qty, done in that order", "saw [" + seen + "]");
    eq_str(seen, "id title qty done ", "and the walk visited them in that order");

    // the values, read back one field at a time, against what was sent
    eq_int(field_int(keep, n, "id"), sent, "id reads back as the id the Location named");
    eq_str(field_str(keep, n, "title"), "jam", "title reads back as jam");
    eq_int(field_int(keep, n, "qty"), 3, "qty reads back as 3");
    ok(!field_is_true(keep, n, "done"), "done reads back as false", "done read as true");

    // re-emitting the parsed values must reproduce the bytes that arrived:
    // parse, rebuild, compare -- the strongest statement available
    // without a second implementation to disagree with
    let rebuilt = "{\"id\":" + tostring(field_int(keep, n, "id")) +
                  ",\"title\":" + jstr(field_str(keep, n, "title")) +
                  ",\"qty\":" + tostring(field_int(keep, n, "qty")) +
                  ",\"done\":" + (if (field_is_true(keep, n, "done")) { "true" } else { "false" }) +
                  "}";
    eq_str(rebuilt, body, "re-emitting the parsed values reproduces the bytes exactly");

    // the listing is an object holding an array of objects, and the count
    // field agrees with the array it sits beside
    let l = ask(base, "GET", "/items", "");
    eq_int(l.status, 200, "the listing is 200");
    let ln = load_into(buf, l.body);
    ok(json.doc(buf, ln), "the listing is a document the parser accepts", json.err);
    let items_at = json.member(buf, 0, ln, "items");
    ok(items_at > 0, "the listing holds an items array", "no items field at all");
    let count = json.nelems(buf, items_at, ln);
    present(count, "the listing's element count");
    eq_int(json_int(l.body, "count"), count, "the listing's count field equals its element count");
    // the fixture was just created, so it is the LAST element -- element
    // count-1. Reading element 0 instead would pass for any listing that
    // happens to start with the right id, which is not this check.
    let last_i = count - 1;
    let last = json.elem(buf, items_at, ln, last_i);
    ok(last > 0, "the listing's last element is inside the array", "at " + tostring(last));
    eq_int(field_int_at(buf, ln, last, "id"), sent,
           "the listing's last element is the fixture just created");
    eq_str(field_str_at(buf, ln, last, "title"), "jam",
           "and its title is the one just sent");
    eq_int(field_int_at(buf, ln, last, "qty"), 3, "and its qty too");

    // a title with a quote in it: the server escapes it, the escape is
    // really on the wire, and decoding gives the original back
    let tricky = "he said \"hi\"";
    let q = ask(base, "POST", "/items", "{\"title\":" + jstr(tricky) + ",\"qty\":1}");
    eq_int(q.status, 201, "a title containing a quote is accepted");
    eq_str(json_str(q.body, "title"), tricky, "and decodes back to the exact original");
    ok(index_of(q.body, "\\\"") > 0, "and the response really carries the escaped quote",
       "no backslash-quote in the body");
    eq_int(json_int(q.body, "qty"), 1, "and the rest of the document survived intact");

    // and the escaped title survives the listing too, so the escape is not
    // undone by the server's own re-emission on the way out
    let l2 = ask(base, "GET", "/items", "");
    eq_int(l2.status, 200, "the listing still answers 200 after a title with an escape");
    let ln2 = load_into(keep, l2.body);
    ok(json.doc(keep, ln2), "and is still a document the parser accepts", json.err);
    let items2 = json.member(keep, 0, ln2, "items");
    let n2 = json.nelems(keep, items2, ln2);
    present(n2, "the second listing's element count");
    let found = false;
    let j = 0;
    while (j < n2 && !found) {
        let e = json.elem(keep, items2, ln2, j);
        if (field_str_at(keep, ln2, e, "title") == tricky) { found = true; };
        j = j + 1;
    };
    ok(found, "the escaped title survives a round trip through the listing",
       "no listed element decoded to the original title");
};

// ── a full collection: the only path where the listing loop really runs ─
//
// The demo and the other checks only ever list one or two items, so the
// walk in show_fields() -- and the "bounded, so not quadratic" claim the -S
// audit makes about it -- are never exercised. The store holds 16 slots, so
// this fills it, reads the whole thing back, and checks it element by
// element. It also measures the arena, because the one way a per-item copy
// in a loop *can* be quadratic is if the string it copies grows across
// iterations; a hard ceiling on the growth is the measurement that says it
// does not.

const FULL = 16;                 // store.y's slot count
const FULL_SLOTS = 48;           // ids to wipe before filling, > FULL

// The ids the creates actually handed out, in order. The check compares the
// listing against *these* and never against an assumed id allocation
// policy -- "element 2 has id 3" is an assumption about the server, and an
// assumption is exactly what makes a check vacuous.
let made_ids: [long; 32] = [0; 32];

def check_full(base: str) {
    puts("\n-- a full collection, listed and walked end to end --\n");
    // make sure there is room: the store may already hold items from the
    // passes above. Ids are not reused after a delete, so the wipe has to
    // cover more than the slot count.
    let i = 1;
    while (i <= FULL_SLOTS) {
        // ask(), not fetch(): every response the check makes goes through
        // one place, so the framing assertion and the one-read-per-response
        // count cannot be dodged by using the other entry point. The reply
        // is not inspected -- check_matrix already asserts what a wipe
        // answers -- but it is counted.
        ask(base, "DELETE", "/items/" + tostring(i), "");
        i = i + 1;
    };
    let made = 0;
    while (made < FULL) {
        let c = ask(base, "POST", "/items",
                    "{\"title\":\"item-" + tostring(made) + "\",\"qty\":" + tostring(made) + "}");
        if (c.status == 201) {
            made_ids[made] = loc_id(c.loc);
            made = made + 1;
        } else {
            // a refusal here is a real failure, and the check must not
            // quietly settle for fewer than a full store
            eq_int(c.status, 201, "create " + tostring(made + 1) + " of the full store");
            made = FULL;
        };
    };
    present(made, "how many creates the full store accepted");
    eq_int(made, FULL, "the store filled to its slot count");

    // the ids are real (each Location parsed to a positive number) and
    // distinct: a store that handed the same id twice would make every
    // element comparison below pass twice over
    let dup = 0;
    let nonpos = 0;
    let k = 0;
    while (k < made) {
        if (made_ids[k] <= 0) { nonpos = nonpos + 1 };
        let m = 0;
        while (m < k) {
            if (made_ids[m] == made_ids[k]) { dup = dup + 1 };
            m = m + 1;
        };
        k = k + 1;
    };
    eq_int(nonpos, 0, "every create answered a positive id in its Location");
    eq_int(dup, 0, "and no two creates were handed the same id");

    // one more create is refused, and the collection does not grow
    let over = ask(base, "POST", "/items", "{\"title\":\"overflow\",\"qty\":1}");
    eq_int(over.status, 507, "one create past the slot count is 507");

    let before = heap_used();
    let l = ask(base, "GET", "/items", "");
    eq_int(l.status, 200, "the full collection lists 200");
    let grew = heap_used() - before;
    let ln = load_into(keep, l.body);
    ok(json.doc(keep, ln), "and the full listing is a document the parser accepts", json.err);
    let items_at = json.member(keep, 0, ln, "items");
    let count = json.nelems(keep, items_at, ln);
    present(count, "the full listing's element count");
    eq_int(count, FULL, "the listing holds every item the store accepted");
    eq_int(json_int(l.body, "count"), count, "and its count field agrees");
    eq_int(store_field(l.store, "live"), FULL, "and the store's own live count agrees");

    // every element, one at a time, against the id and title its own create
    // answered -- a listing that dropped, duplicated or reordered an
    // element fails here
    let j = 0;
    let bad = 0;
    let first_bad = "";
    while (j < count) {
        let e = json.elem(keep, items_at, ln, j);
        if (e < 0) {
            bad = bad + 1;
            if (first_bad == "") { first_bad = "element " + tostring(j) + " is not in the array" };
        } else {
            let want_title = "item-" + tostring(j);
            if (field_int_at(keep, ln, e, "id") != made_ids[j] ||
                field_str_at(keep, ln, e, "title") != want_title ||
                field_int_at(keep, ln, e, "qty") != j) {
                bad = bad + 1;
                if (first_bad == "") { first_bad = "element " + tostring(j) +
                    " should be id " + tostring(made_ids[j]) + " title [" + want_title + "]" };
            }
        };
        j = j + 1;
    };
    eq_int(bad, 0, "every listed element is the item that was created at that id");
    ok(first_bad == "", "  ...and the first mismatch, if any, is named", first_bad);

    // The measurement: parsing and walking the whole listing must not cost
    // an arena that grows with the square of the item count. The ceiling is
    // deliberately loose -- 96 KB against a body of well under 2 KB -- so
    // this cannot flake, but a quadratic would blow straight through it.
    ok(grew < 98304, "the full listing costs a bounded arena, not a quadratic one",
       "heap_used() grew " + tostring(grew) + " bytes listing " + tostring(count) + " items");

    // The same listing through the *display* path -- show_fields() is the
    // function the -S audit reports, and it is the only loop in this client
    // that runs once per field per item. Its 15 `y_str_cat` sites each build
    // one bounded line that goes straight to puts(), so nothing grows across
    // iterations; this measures that claim instead of asserting it. The
    // lines it prints are the listing, walked -- which is the point of
    // putting a full collection through it.
    puts("      -- the same listing, walked by show_fields() --\n");
    let d0 = heap_used();
    show_body(l.body, "      ");
    let display = heap_used() - d0;
    ok(display < 98304, "displaying the whole listing costs a bounded arena too",
       "heap_used() grew " + tostring(display) + " bytes displaying " + tostring(count) +
       " items -- a per-iteration copy that grew would be quadratic");

    // and a delete still works with the store full
    let victim = made_ids[2];
    present(victim, "the id of the element to delete");
    let d1 = ask(base, "DELETE", "/items/" + tostring(victim), "");
    eq_int(d1.status, 204, "a delete from the full store is still 204");
    let l2 = ask(base, "GET", "/items", "");
    eq_int(json_int(l2.body, "count"), FULL - 1, "and the listing loses exactly that one");
};

// field readers that take the document already in `b`, so a round trip
// never has to reload the buffer under itself
def field_int(b: [byte; 65536], end: long, key: str) -> long {
    let at = json.member(b, 0, end, key);
    if (at < 0) { 0 - 999997 } else {
        json.int_at(b, at, end);
        if (json.iok) { json.ival } else { 0 - 999998 }
    }
};

def field_str(b: [byte; 65536], end: long, key: str) -> str {
    let at = json.member(b, 0, end, key);
    if (at < 0) { "" } else {
        let k = json.text_into(b, at, end, valbuf);
        if (k < 0) { "" } else { from_bytes(valbuf[0:k]) }
    }
};

def field_is_true(b: [byte; 65536], end: long, key: str) -> bool {
    let at = json.member(b, 0, end, key);
    if (at < 0) { return false; };
    // bool_at, not text_is: `done` is a bare JSON literal on the wire, and
    // text_is only ever matches the *quoted* word, so it would answer
    // "false" for every document including the ones that say true
    json.bool_at(b, at, end) == 1
};

def field_int_at(b: [byte; 65536], end: long, at: long, key: str) -> long {
    let v = json.member(b, at, end, key);
    if (v < 0) { 0 - 999997 } else {
        json.int_at(b, v, end);
        if (json.iok) { json.ival } else { 0 - 999998 }
    }
};

def field_str_at(b: [byte; 65536], end: long, at: long, key: str) -> str {
    let v = json.member(b, at, end, key);
    if (v < 0) { "" } else {
        let k = json.text_into(b, v, end, valbuf);
        if (k < 0) { "" } else { from_bytes(valbuf[0:k]) }
    }
};

// document-level readers, for the checks that only want a value: the
// sentinels are not numbers a caller is likely to expect, so a field that
// never arrived cannot compare equal to a real one.
def json_int(doc_text: str, key: str) -> long {
    let n = load_into(keep, doc_text);
    if (!json.doc(keep, n)) { 0 - 999999 } else {
        let at = json.member(keep, 0, n, key);
        if (at < 0) {
            0 - 999998
        } else {
            json.int_at(keep, at, n);
            if (json.iok) { json.ival } else { 0 - 999997 }
        }
    }
};

// does the document hold that key at all? A field that is absent has to be
// provable, not inferred from a value that happens to look like zero.
def json_has(doc_text: str, key: str) -> bool {
    let n = load_into(keep, doc_text);
    if (!json.doc(keep, n)) { return false; };
    json.member(keep, 0, n, key) >= 0
};

def json_str(doc_text: str, key: str) -> str {
    let n = load_into(keep, doc_text);
    if (!json.doc(keep, n)) { "" } else {
        let at = json.member(keep, 0, n, key);
        if (at < 0) { "" } else {
            let k = json.text_into(keep, at, n, valbuf);
            if (k < 0) { "" } else { from_bytes(valbuf[0:k]) }
        }
    }
};

// ── the read-once property, and the bug it works around ───────────────

def check_text_once(base: str) {
    puts("\n-- Response.text() is read exactly once per response --\n");
    present(c_replies, "the number of responses the check received");
    eq_int(text_reads, c_replies, "one text() read per response, and no more");
    // a request the check made through ask() rather than fetch() would
    // show up here as a read that does not match a response
    eq_int(c_framed, c_replies, "every response's framing was asserted");

    // and the bug this is a workaround for is still there, reproduced on
    // purpose: a second read of the *same* response comes back empty,
    // with no diagnostic. Read once here on purpose -- that is the point.
    let res = http.get(base + "/items", ct_opts());
    let first = res.text();
    present(len(first), "the first read of a response body");
    let second = res.text();
    eq_int(len(second), 0,
           "a second Response.text() is empty -- the filed bug, reproduced on purpose");
    ok(len(first) > len(second), "and it was not because the body was empty",
       "first " + tostring(len(first)) + ", second " + tostring(len(second)));
};

// ── the harness itself ────────────────────────────────────────────────

// The harness proving it can tell a failure from a pass. Two agents in this
// campaign shipped checks that compared two absent values and passed; the
// only real defence is to make sure a false condition *would* have been
// caught. So one assertion here is made false on purpose, and the tally is
// required to move.
def check_harness() {
    puts("\n-- the harness can tell a failure from a pass --\n");
    let before = c_fails;
    hush = true;
    eq_int(0, 1, "a condition that cannot hold is reported");
    hush = false;
    let counted = c_fails == before + 1;
    c_fails = before;          // that one was deliberate: do not report it
    ok(counted, "so a check whose comparisons were all vacuous would still look different",
       "the failure tally went " + tostring(before) + " -> " + tostring(before + 1) +
       ", so a vacuous pass is not silently a success");
};

def self_test() -> long {
    puts("== property check: rest-client ==\n");
    puts("   compiler pin 6dcd7071f2fe3875 (the full sha256 is in README.md)\n");
    puts("   the server is forked from this process and stopped with SIGTERM\n");
    check_harness();
    check_parser();
    let port = server.start();
    if (port <= 0) {
        eputs("rest-client: the check needs a server, and none started (errno " +
              tostring(server.start_err) + ")\n");
        return 1;
    };
    let base = "http://127.0.0.1:" + tostring(port);
    check_crud(base);
    check_matrix(base, made_so_far);
    check_roundtrip(base);
    check_full(base);
    check_text_once(base);
    puts("\n-- the totals --\n");
    let code = shut();
    puts("   responses: " + tostring(c_replies) + "   checks: " + tostring(c_checks) +
         "   failures: " + tostring(c_fails) + "\n");
    puts("   server stopped with " + tostring(code) + "\n");
    if (c_fails > 0) {
        puts("\nproperty check: FAILED -- " + tostring(c_fails) + " of " + tostring(c_checks) +
             " checks failed\n");
        return 1;
    };
    if (c_checks < 100) {
        puts("\nproperty check: only " + tostring(c_checks) + " checks ran, which is too few to mean much\n");
        return 1;
    };
    puts("\nproperty check: OK -- " + tostring(c_checks) + " checks, 0 failures\n");
    0
};

// ── the TLS stage ──────────────────────────────────────────────────────
//
// Opt-in, never in the default path, never in EXPECTED, and never in
// gate.conf's check= -- it needs openssl, and the gate must not fail over
// that. It SKIPs cleanly and exits 0 when openssl is not on PATH.
//
// `anchors:` is the certificate's PEM *text*, not a path: std/tls hands the
// string to x509.anchors_pem, and a path would parse as no anchors at all.
// And the certificate carries DNS:127.0.0.1 as well as IP:127.0.0.1,
// because x509 reads only dNSName SANs -- with the IP SAN alone it refuses
// its own certificate (examples/SUGGESTIONS.md section 14).

const TLS_DIR = "/tmp/rest-client-tls";
const TLS_PAYLOAD = "tls payload: the bytes over the wire are these bytes\n";

let tls_fail = 0;

// a 16-byte struct sockaddr_in for the port sniffer, module-level because
// it is taken by address
let tls_sa: [byte; 16] = [0; 16];

def tls_want(cond: bool, what: str, detail: str) {
    if (cond) {
        puts("  ok   " + what + "\n");
    } else {
        tls_fail = tls_fail + 1;
        puts("  FAIL " + what + "\n");
        puts("       " + detail + "\n");
    }
};

def q(s: str) -> str { "'" + s + "'" };

// A port nothing is listening on yet: bind 0, read what the kernel gave,
// close. A tiny race window on loopback, which is the price of not asking
// s_server where it bound -- `-accept 0` does not report the port.
def spare_port() -> long {
    let fd = net.socket_tcp();
    if (fd < 0) { return 0; };
    tls_sa[0] = 2;             // AF_INET
    tls_sa[1] = 0;
    tls_sa[4] = 127;           // loopback only
    tls_sa[7] = 1;
    if (syscall(49, fd, &tls_sa[0], 16) < 0) {
        net.close_fd(fd);
        return 0;
    };
    let p = net.local_port(fd);
    net.close_fd(fd);
    p
};

def tls_selftest() -> long {
    puts("== TLS stage: rest-client against openssl s_server ==\n");
    puts("   not part of EXPECTED and not part of the gate's check=\n");
    if (exec("openssl version > /dev/null 2>&1") != 0) {
        puts("\nSKIP: openssl is not on PATH, so the TLS stage did not run.\n");
        puts("      This never fails the gate -- it is not in check=.\n");
        return 0;
    };
    fs.remove_all(TLS_DIR);
    if (!fs.make_dir(TLS_DIR)) {
        eputs("rest-client: could not make " + TLS_DIR + "\n");
        return 1;
    };
    let rc = exec("cd " + q(TLS_DIR) + " && openssl req -x509 -newkey rsa:2048 -keyout key.pem" +
                  " -out cert.pem -days 365 -nodes -subj /CN=127.0.0.1" +
                  " -addext " + q("subjectAltName=DNS:127.0.0.1,IP:127.0.0.1") +
                  " > /dev/null 2>&1");
    if (rc != 0 || !fs.is_file(TLS_DIR + "/cert.pem")) {
        eputs("rest-client: openssl did not produce a certificate\n");
        return 1;
    };
    // the payload the server will serve over TLS
    fs.write_file(TLS_DIR + "/index.txt", TLS_PAYLOAD);
    let port = spare_port();
    if (port <= 0) {
        eputs("rest-client: could not find a spare loopback port\n");
        return 1;
    };
    let base = "https://127.0.0.1:" + tostring(port);
    // s_server -WWW answers with real HTTP headers (unlike -HTTP, which
    // answers HTTP/0.9 and no client can parse). Its output goes to
    // /dev/null so it cannot corrupt this program's stdout.
    //
    // setsid, then kill the whole process group. `exec()` is `/bin/sh -c`,
    // so the child that fork() returns is the *shell*, and openssl is its
    // child: SIGTERM to the shell alone killed the shell (so wait4 said
    // 143, and the check passed) and left every openssl s_server alive on
    // the machine. Seven of them were still listening when this was found.
    let srv = fork {
        syscall(112, 0);       // setsid: this child leads its own group
        exec("cd " + q(TLS_DIR) + " && openssl s_server -accept " + tostring(port) +
             " -cert cert.pem -key key.pem -WWW -quiet > /dev/null 2>&1")
    };
    // the anchors are the certificate's PEM text, read once
    let pem = fs.read_file(TLS_DIR + "/cert.pem");
    if (pem == none) {
        eputs("rest-client: could not read the certificate back\n");
        syscall(62, srv, 15);
        wait_pid(srv);
        return 1;
    };
    // s_server needs a moment to bind; retry rather than sleep a fixed guess
    let got = 0;
    let tries = 0;
    let body = "";
    let status = 0;
    let err = "";
    let ct = "";
    while (tries < 40 && status != 200) {
        let res = http.get(base + "/index.txt", { anchors: pem!, timeout: TIMEOUT });
        err = res.err;
        if (err == "") {
            status = res.status;
            let c = res.headers["content-type"];
            if (c != none) { ct = c! };
            body = res.text();        // read once -- see the BUGS.md entry
            got = got + 1;
        } else {
            sleep(50);
        };
        tries = tries + 1;
    };
    tls_want(got > 0, "a TLS 1.3 GET to openssl s_server completed a handshake",
             "no attempt reached the server; last error [" + err + "] after " +
             tostring(tries) + " tries on " + base);
    tls_want(status == 200, "and it answered 200", "status " + tostring(status) +
             ", err [" + err + "]");
    tls_want(len(body) > 0, "the body is not empty",
             "the TLS read returned 0 bytes, so every content comparison below would be vacuous");
    tls_want(body == TLS_PAYLOAD,
             "the bytes over TLS are byte-for-byte the bytes written",
             "got [" + body + "], want [" + TLS_PAYLOAD + "]");
    tls_want(ct == "text/plain", "and the content type came back over TLS",
             "got [" + ct + "]");
    // s_server -WWW answers 200 even for a path it does not have -- it is a
    // file server, not an origin that returns 404 -- so the honest
    // assertion is that the bytes differ from the payload. Asserting
    // "status != 200" here would be asserting something false about
    // openssl, and it would fail for a reason that has nothing to do with
    // the client under test.
    let miss = http.get(base + "/no-such-file.txt", { anchors: pem!, timeout: TIMEOUT });
    let missbody = miss.text();
    tls_want(len(missbody) > 0, "a missing path over TLS really answered, with a body",
             "it returned 0 bytes, so the server never spoke");
    tls_want(missbody != TLS_PAYLOAD, "and the body is NOT the payload we wrote",
             "s_server served the same bytes for a file that does not exist, so the 200 above proves nothing");
    // and the chain is actually being verified: the same request with the
    // anchors removed must fail, or `anchors` is not reaching x509 at all
    let noanchor = http.get(base + "/index.txt", { timeout: TIMEOUT });
    let nobody = noanchor.text();
    tls_want(noanchor.status != 200,
             "and the same request without anchors is refused, so the chain really is checked",
             "an unauthenticated fetch of a self-signed server answered " +
             tostring(noanchor.status) + " -- the anchor was not consulted");
    tls_want(len(nobody) == 0, "and the refused fetch returned no body at all",
             "it returned " + tostring(len(nobody)) + " bytes, so the handshake went through anyway");
    // stop the server and clean up. The group, not the shell: see the
    // setsid comment at the fork above.
    syscall(62, 0 - srv, 15);
    let code = wait_pid(srv);
    tls_want(code == 143, "the s_server child stopped on SIGTERM",
             "wait4 said " + tostring(code) + ", not 143");
    // ... and the assertion that would have caught the leak: nothing is
    // listening on that port any more. wait4 said 143 while seven
    // openssl s_servers were still running, because it was only ever
    // reporting on the shell. The kill is asynchronous, so this polls:
    // a refused connect is the evidence, not the shell's exit status.
    let gone = 0 - 1;
    let tries = 0;
    while (tries < 50 && gone >= 0) {
        gone = net.connect_tcp("127.0.0.1", port);
        if (gone >= 0) {
            net.close_fd(gone);
            sleep(20);
        };
        tries = tries + 1;
    };
    tls_want(gone < 0, "and nothing is listening on that port any more",
             "something still accepted on port " + tostring(port) + " after " +
             tostring(tries) + " probes -- the s_server outlived its SIGTERM");
    fs.remove_all(TLS_DIR);
    if (tls_fail > 0) {
        puts("\nTLS stage: FAILED -- " + tostring(tls_fail) + " checks failed\n");
        return 1;
    };
    puts("\nTLS stage: OK -- TLS 1.3 handshake, chain verified against the PEM anchor,\n");
    puts("            payload byte-identical, and refused without the anchor\n");
    0
};

// ── --live: the one path that leaves the machine ───────────────────────
//
// Never in the default run and never in EXPECTED or check=. It reports what
// the endpoint said and nothing more: no store, no matrix, no assertion
// about a body this program does not own.

def cmd_live(url: str, method: str) -> long {
    if (url == "") {
        eputs("rest-client: --live needs a URL\n");
        return 2;
    };
    let opts: {str => str} = { "Accept": "application/json" };
    let o: http.Opts = { headers: opts, body: args.get_str("body", ""),
                         insecure: args.has("insecure"), timeout: 20 };
    let r = http.request(method, url, o);
    let text = r.text();        // read once, as everywhere else
    puts("-- " + method + " " + url + "\n");
    puts("   HTTP/1.1 " + tostring(r.status) + " " + r.reason + "\n");
    if (r.err != "") {
        eputs("rest-client: " + r.err + "\n");
        return 1;
    };
    puts("   " + tostring(len(text)) + " bytes of body\n");
    if (len(text) > 0 && len(text) < 4000) { puts(text + "\n") };
    if (r.status >= 200 && r.status < 300) { 0 } else { 1 }
};

// ── the entry point ───────────────────────────────────────────────────

const TAIL = "[command] [--title=T] [--qty=N] [--id=N] [--done] [--body=JSON] [-v]\n" +
             "         [--self-test] [--tls-selftest] [--live URL [METHOD]] [--insecure]";

def main() -> long {
    args.init("rest-client", "a REST client over loopback: four verbs, seven statuses",
              OPTS, TAIL);
    args.parse_or_exit(argv());
    verbose = args.has("verbose");
    if (args.has("self-test")) { return self_test(); };
    let files = args.positional();
    // --live short-circuits everything else: the one invocation that talks
    // to a machine that is not this one, so it is never in the default path
    if (args.has("live")) {
        if (len(files) < 1) {
            eputs("rest-client: --live needs a URL\n");
            return 2;
        };
        let m = "GET";
        if (len(files) > 1) { m = files[1]; };
        return cmd_live(files[0], m);
    };
    if (args.has("tls-selftest")) { return tls_selftest(); };
    let cmd = "demo";
    if (len(files) > 0) { cmd = files[0]; };
    if (cmd == "demo") {
        demo()
    } else if (cmd == "list") {
        cmd_list()
    } else if (cmd == "read") {
        if (len(files) < 2) {
            eputs("rest-client: read needs an id\n");
            return 2;
        };
        cmd_read(need_positive("read", tonum(files[1])))
    } else if (cmd == "update" || cmd == "delete") {
        if (len(files) < 2) {
            eputs("rest-client: " + cmd + " needs an id\n");
            return 2;
        };
        let id = need_positive(cmd, tonum(files[1]));
        if (cmd == "update") { cmd_update(id) } else { cmd_delete(id) }
    } else if (cmd == "create") {
        cmd_create()
    } else if (cmd == "shell") {
        cmd_shell()
    } else if (cmd == "help") {
        puts(args.usage());
        0
    } else {
        eputs("rest-client: unknown command [" + cmd + "]\n");
        eputs("rest-client: try demo, list, read ID, create, update ID, delete ID, shell, tls-selftest\n");
        2
    }
}; exit(main())
