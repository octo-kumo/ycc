// server.y -- the loopback REST server behind rest-client.
//
//   import server;
//
//   let port = server.start();      // bind, listen, fork: the port is the answer
//   ... http.get("http://127.0.0.1:" + tostring(port) + "/items") ...
//   let code = server.stop();       // SIGTERM, then the child's 143
//
// ── why the socket is made in the parent ──────────────────────────────
//
// `net.listen_http(port, handler)` is one line and it works, but it
// re-binds the port itself, so it cannot take over a socket it was
// handed: on an inherited socket bind fails with errno -98 and the call
// exits, having served nothing. So this module does the three syscalls
// itself -- socket(2) 41, bind(2) 49, listen(2) 50 -- on **127.0.0.1**
// only, forks, and the child serves with `net.accept_tcp` on the socket
// it inherited. `net.listen_fd` is the one std call it can use here,
// because it does not re-bind.
//
// Two reasons for that shape beyond the errno:
//
//   * The port is known **before** the fork, so the parent needs no pipe
//     to be told it (a pipe's two fds come back as 32-bit ints packed into
//     a [long; 2] whose write end reads as 0, which is stdin, and a hang
//     that looks like nothing at all). Port 0 asks the kernel for a free
//     one, so two copies of this example can share a machine.
//   * The server must be stoppable. `net.listen_http` never returns and Y
//     has no signal handlers, so the answer is fork + kill(2) 62 with
//     signal 15; the child then reports 143 = 128 + 15 through wait_pid,
//     which is how a caller tells a stopped server from a crashed one.
//
// ── where the bytes go ────────────────────────────────────────────────
//
// The head and the request body share one fixed buffer, because they are
// one byte stream: rbuf[0:head_end] is the head and rbuf[head_end:got]
// is the body, so no gap can appear between them. A response is built
// with its head at 0 and its body at BODY_AT and sent as **two** writes:
// one write from offset 0 would put the NULs between them on the wire,
// and a client that trusts Content-Length would read a body of zeros.
//
// Nothing here allocates per request. The arena never frees, so a literal
// array or record inside a per-request function costs 64/40 bytes a call
// for ever; the buffers are module level and the body is written digit by
// digit into obuf. The two places that do allocate are the error bodies
// that quote the request target back (`slice_path`) and the title that
// came in (`sbuf` -> from_bytes), and they are the right trade: a few
// dozen bytes on a diagnostic, against zero on the hot path.

import net;
import json;
import store;

// ── the buffers ───────────────────────────────────────────────────────
const CAP = 65536;
const BODY_AT = 1024;         // room for the response head, then the body
const MAX_HEAD = 4096;        // a longer head is 431
const MAX_BODY = 4096;        // a longer body is 413

let rbuf: [byte; 65536] = [0; 65536];
let obuf: [byte; 65536] = [0; 65536];
let sbuf: [byte; 256] = [0; 256];
let digits: [byte; 24] = [0; 24];
let sa: [byte; 16] = [0; 16];

// ── the socket and the child ──────────────────────────────────────────
let lfd = 0;                  // the listening socket (inherited)
let port = 0;
let pid = 0;                  // the forked child
let start_err = 0;            // why start() answered 0
let child_status = 0;         // what the child ended with: 143 after stop()

// ── what the server did ───────────────────────────────────────────────
let served = 0;               // requests answered, any status
let by_code: [long; 10] = [0; 10];   // index: status / 100

// ── the request being served ──────────────────────────────────────────
let got = 0;
let head_end = 0;
let body_at = 0;
let body_len = 0;
let clen = 0;
let m_code = 0;               // M_GET, M_POST, M_PUT, M_DEL or M_OTHER
let path_at = 0;              // the target, query string stripped
let path_len = 0;
let id = 0;                   // the id in /items/<id>
let id_seen = false;
let id_ok = true;

// ── the response being built ──────────────────────────────────────────
let r_code = 200;             // the status being sent
let r_ctype = "application/json";
let r_loc = "";               // the Location header, "" for none
let r_allow = "";             // the Allow header, "" for none
let r_blen = 0;               // how many body bytes sit at BODY_AT

const M_GET = 0;
const M_POST = 1;
const M_PUT = 2;
const M_DEL = 3;
const M_OTHER = 4;

const ALLOW_COLLECTION = "GET, POST";
const ALLOW_ITEM = "GET, PUT, DELETE";

// ── writing into obuf ─────────────────────────────────────────────────

def w(p: long, s: str) -> long {
    let n = len(s);
    let i = 0;
    while (i < n) { obuf[p + i] = s[i]; i = i + 1; };
    p + n
};

// a decimal long. The scratch is module level: a [byte; 24] inside a
// per-request function would be 64 bytes a call, for ever.
def wn(p: long, v: long) -> long {
    let n = 0;
    let x = v;
    let neg = x < 0;
    if (neg) { x = 0 - x; };
    if (x == 0) { digits[0] = 48; n = 1; };
    while (x > 0) {
        digits[n] = 48 + (x % 10);
        n = n + 1;
        x = x / 10;
    };
    if (neg) { obuf[p] = 45; p = p + 1; };
    let i = 0;
    while (i < n) { obuf[p + i] = digits[n - 1 - i]; i = i + 1; };
    p + n
};

// A JSON string, quotes and all, with what the grammar requires escaped.
// A title is the only caller-supplied string that reaches a response, so
// this is what stops a title carrying a quote from breaking the document
// -- and what lets the property check send one.
def wstr(p: long, s: str) -> long {
    obuf[p] = 34;
    p = p + 1;
    let n = len(s);
    let i = 0;
    while (i < n) {
        let c = s[i];
        if (c == 34 || c == 92) {
            obuf[p] = 92;
            obuf[p + 1] = c;
            p = p + 2;
        } else if (c == 10 || c == 9 || c == 13) {
            obuf[p] = 92;
            obuf[p + 1] = 116;              // \t
            if (c == 10) { obuf[p + 1] = 110; };
            if (c == 13) { obuf[p + 1] = 114; };
            p = p + 2;
        } else if (c < 32) {
            let hexd = "0123456789abcdef";
            obuf[p] = 92; obuf[p + 1] = 117; obuf[p + 2] = 48; obuf[p + 3] = 48;
            p = p + 4;
            obuf[p] = hexd[c / 16];
            p = p + 1;
            obuf[p] = hexd[c % 16];
            p = p + 1;
        } else {
            obuf[p] = c;
            p = p + 1;
        };
        i = i + 1;
    };
    obuf[p] = 34;
    p + 1
};

// write(2) until it is all gone: a short write on a socket is legal, and
// dropping the tail of a response is a defect the client can see.
def write_all(fd: long, off: long, n: long) {
    let left = 0;
    while (left < n) {
        let k = syscall(1, fd, &obuf[off + left], n - left);
        if (k <= 0) { left = n; } else { left = left + k; };
    };
};

// ── the response head ─────────────────────────────────────────────────

def reason_of(code: long) -> str {
    if (code == 200) { "OK" } else {
        if (code == 201) { "Created" } else {
            if (code == 204) { "No Content" } else {
                if (code == 400) { "Bad Request" } else {
                    if (code == 404) { "Not Found" } else {
                        if (code == 405) { "Method Not Allowed" } else {
                            if (code == 409) { "Conflict" } else {
                                if (code == 413) { "Payload Too Large" } else {
                                    if (code == 431) { "Request Header Fields Too Large" } else {
                                        if (code == 507) { "Insufficient Storage" } else { "Error" }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
};

// Build the head at 0 and send it with the body. Two writes, head first,
// because the body sits at BODY_AT and not at p.
def answer(fd: long, code: long) {
    let p = 0;
    p = w(p, "HTTP/1.1 ");
    p = wn(p, code);
    p = w(p, " ");
    p = w(p, reason_of(code));
    p = w(p, "\r\nServer: rest-client/1 (y)\r\n");
    // 204 carries no body, so it carries no type either
    if (code != 204) {
        p = w(p, "Content-Type: ");
        p = w(p, r_ctype);
        p = w(p, "\r\n");
    };
    p = w(p, "Content-Length: ");
    p = wn(p, r_blen);
    p = w(p, "\r\n");
    if (r_loc != "") {
        p = w(p, "Location: ");
        p = w(p, r_loc);
        p = w(p, "\r\n");
    };
    if (r_allow != "") {
        p = w(p, "Allow: ");
        p = w(p, r_allow);
        p = w(p, "\r\n");
    };
    // The store's own account of itself, as headers. It is a second and
    // independent count of what happened, which is what lets the
    // property check compare the client's view with the server's instead
    // of with its own arithmetic twice.
    p = w(p, "X-Store: live=");
    p = wn(p, store.live());
    p = w(p, " created=");
    p = wn(p, store.created());
    p = w(p, " updated=");
    p = wn(p, store.updated());
    p = w(p, " deleted=");
    p = wn(p, store.deleted());
    p = w(p, " rejected=");
    p = wn(p, store.rejected());
    p = w(p, "\r\nConnection: close\r\n\r\n");
    // A guard, not a clamp: the head is ~250 bytes against BODY_AT's
    // 1024, so a future header cannot quietly eat the front of a body.
    if (p > BODY_AT) { p = BODY_AT; };
    write_all(fd, 0, p);
    write_all(fd, BODY_AT, r_blen);
    served = served + 1;
    by_code[code / 100] = by_code[code / 100] + 1;
};

// ── the bodies ────────────────────────────────────────────────────────
//
// Each writes at BODY_AT and leaves its length in r_blen, setting r_code
// on the way. `item_into` takes the offset because the listing embeds
// items inside one array -- a fixed BODY_AT there would overwrite the
// array it is building.

def item_into(p: long, at: long) -> long {
    p = w(p, "{\"id\":");
    p = wn(p, store.s_id[at]);
    p = w(p, ",\"title\":");
    p = wstr(p, store.s_title[at]);
    p = w(p, ",\"qty\":");
    p = wn(p, store.s_qty[at]);
    p = w(p, ",\"done\":");
    p = w(p, if (store.s_done[at]) { "true" } else { "false" });
    p = w(p, "}");
    p
};

def item_at(at: long) -> long {
    item_into(BODY_AT, at) - BODY_AT
};

// {"count":N,"items":[...]} -- the live resources in ascending id order
def list_body() -> long {
    let p = BODY_AT;
    p = w(p, "{\"count\":");
    p = wn(p, store.live());
    p = w(p, ",\"items\":[");
    let i = 0;
    let n = store.live();
    while (i < n) {
        if (i > 0) { p = w(p, ","); };
        p = item_into(p, store.order(i));
        i = i + 1;
    };
    p = w(p, "]}");
    p - BODY_AT
};

// Every error body is written in one go at BODY_AT, fields in a fixed
// order, and carries the field that explains it: the id that was not
// found, the Allow set, the reason the body was refused. A check can
// then assert on a field rather than on prose.

def no_route_body() -> long {
    r_code = 404;
    r_ctype = "application/json";
    let p = BODY_AT;
    // the target is quoted back, which is the one place a bad request can
    // put arbitrary bytes into a response: wstr is what makes that safe
    p = w(p, "{\"error\":\"no such resource\",\"status\":404,\"path\":");
    p = wstr(p, from_bytes(rbuf[path_at : path_at + path_len]));
    p = w(p, "}");
    p - BODY_AT
};

def bad_id_body() -> long {
    r_code = 400;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"the id must be digits\",\"status\":400,\"id\":");
    p = wn(p, id);
    p = w(p, "}");
    p - BODY_AT
};

def missing_item_body() -> long {
    r_code = 404;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"no such item\",\"status\":404,\"id\":");
    p = wn(p, id);
    p = w(p, "}");
    p - BODY_AT
};

def no_method_body(allow: str) -> long {
    r_code = 405;
    r_ctype = "application/json";
    r_allow = allow;
    let p = BODY_AT;
    p = w(p, "{\"error\":\"method not allowed\",\"status\":405,\"allowed\":");
    p = wstr(p, allow);
    p = w(p, "}");
    p - BODY_AT
};

def conflict_body(want: long) -> long {
    r_code = 409;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"that id is taken\",\"status\":409,\"id\":");
    p = wn(p, want);
    p = w(p, "}");
    p - BODY_AT
};

def full_body() -> long {
    r_code = 507;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"the collection is full\",\"status\":507,\"max\":16}");
    p - BODY_AT
};

// A body that could not be read, with the reason it could not. The reason
// is a fixed word chosen in parse_body, never the parser's own text, so
// this body cannot change with the parser's wording.
def bad_body_body(why: str) -> long {
    r_code = 400;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"bad request body\",\"status\":400,\"why\":");
    p = wstr(p, why);
    p = w(p, "}");
    p - BODY_AT
};

def head_too_long_body() -> long {
    r_code = 431;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"the request head is too long\",\"status\":431,\"max\":4096}");
    p - BODY_AT
};

def bad_line_body() -> long {
    r_code = 400;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"bad request line\",\"status\":400}");
    p - BODY_AT
};

def body_too_long_body() -> long {
    r_code = 413;
    r_ctype = "application/json";
    let p = BODY_AT;
    p = w(p, "{\"error\":\"the body is too long\",\"status\":413,\"max\":4096}");
    p - BODY_AT
};

def ok_text_body() -> long {
    r_code = 200;
    r_ctype = "text/plain; charset=utf-8";
    w(BODY_AT, "ok\n") - BODY_AT
};

// ── the request body ──────────────────────────────────────────────────
//
// title: str and qty: long are required; id and done are optional.
// Anything else -- no title, a title that is not a string, a qty that is
// not an integer, a title over 120 bytes -- is a 400 naming which, so the
// client's error path has something to read and the check can assert on
// the field rather than on prose.

let want_id = 0;
let have_id = false;
let want_qty = 0;
let want_done = false;
let want_title = "";
let body_bad = "";

def parse_body() -> bool {
    body_bad = "";
    have_id = false;
    want_done = false;
    want_title = "";
    let end0 = body_at + body_len;
    if (body_len <= 0) {
        body_bad = "a body is required";
        return false;
    };
    // the document starts where the body starts, not at 0 -- doc_at, not
    // doc: rbuf[0:body_at] is the request head, and handing the head to a
    // JSON parser answers every POST with "the body is not JSON"
    if (!json.doc_at(rbuf, body_at, body_at + body_len)) {
        body_bad = "the body is not JSON";
        return false;
    };
    if (rbuf[body_at] != 123) {
        body_bad = "the body must be an object";
        return false;
    };
    let at = json.member(rbuf, body_at, end0, "title");
    if (at < 0) {
        body_bad = "title is required";
        return false;
    };
    let n = json.text_into(rbuf, at, end0, sbuf);
    if (n < 0) {
        body_bad = "title must be a string";
        return false;
    };
    if (n > 120) {
        body_bad = "title is longer than 120 bytes";
        return false;
    };
    want_title = from_bytes(sbuf[0:n]);
    let q = json.member(rbuf, body_at, end0, "qty");
    if (q < 0) {
        body_bad = "qty is required";
        return false;
    };
    let qv = json.int_at(rbuf, q, end0);
    if (!json.iok) {
        body_bad = "qty must be an integer";
        return false;
    };
    if (qv < 0) {
        body_bad = "qty must not be negative";
        return false;
    };
    want_qty = qv;
    let d = json.member(rbuf, body_at, end0, "done");
    if (d >= 0) {
        // a bare JSON literal, not the quoted word json.text_is() wants:
        // "done": true, which is what a REST body actually carries
        let dv = json.bool_at(rbuf, d, end0);
        if (dv < 0) {
            body_bad = "done must be true or false";
            return false;
        };
        want_done = dv == 1;
    };
    let i0 = json.member(rbuf, body_at, end0, "id");
    if (i0 >= 0) {
        let iv = json.int_at(rbuf, i0, end0);
        if (!json.iok) {
            body_bad = "id must be an integer";
            return false;
        };
        if (iv < 1) {
            body_bad = "id must be positive";
            return false;
        };
        want_id = iv;
        have_id = true;
    };
    true
};

// ── the routes ────────────────────────────────────────────────────────

def tok(at0: long, s: str) -> bool {
    let n = len(s);
    if (at0 + n > path_at + path_len) { return false; };
    let i = 0;
    let same = true;
    while (i < n) {
        if (rbuf[at0 + i] != s[i]) { same = false; };
        i = i + 1;
    };
    same
};

def route(fd: long) {
    r_code = 200;
    r_ctype = "application/json";
    r_loc = "";
    r_allow = "";
    r_blen = 0;
    id = 0;
    id_seen = false;
    id_ok = true;
    // /healthz -- a liveness line, so a human can curl the server. It is a
    // resource like any other, so a verb it does not support is a 405 with
    // an Allow of its own, not a 200.
    if (path_len == 8 && tok(path_at, "/healthz")) {
        if (m_code == M_GET) {
            r_blen = ok_text_body();
            answer(fd, r_code);
        } else {
            r_blen = no_method_body("GET");
            answer(fd, 405);
        };
        return;
    };
    if (!(path_len >= 6 && tok(path_at, "/items"))) {
        r_blen = no_route_body();
        answer(fd, 404);
        return;
    };
    // /items, or /items/<id>
    let rest_at = path_at + 6;
    let rest_len = path_len - 6;
    id_seen = rest_len > 0;
    if (rest_len > 0) {
        if (rbuf[rest_at] != 47) {
            r_blen = no_route_body();
            answer(fd, 404);
            return;
        };
        let i = rest_at + 1;
        let deep = false;
        while (i < path_at + path_len) {
            let c = rbuf[i];
            if (c == 47) {
                deep = true;
            } else if (c < 48 || c > 57) {
                id_ok = false;
            } else {
                if (id < 1000000) { id = id * 10 + (c - 48); } else { id_ok = false; };
            };
            i = i + 1;
        };
        // /items/1/2 is not a bad id, it is a path that does not exist:
        // a second slash means there is no such route
        if (deep) {
            r_blen = no_route_body();
            answer(fd, 404);
            return;
        };
        // an empty id (/items/) is as wrong as a non-numeric one
        if (i == rest_at + 1) { id_ok = false; };
    };
    if (id_seen && !id_ok) {
        r_blen = bad_id_body();
        answer(fd, 400);
        return;
    };
    // the collection
    if (!id_seen) {
        if (m_code == M_GET) {
            r_code = 200;
            r_blen = list_body();
            answer(fd, 200);
        } else if (m_code == M_POST) {
            if (!parse_body()) {
                r_blen = bad_body_body(body_bad);
                answer(fd, 400);
                return;
            };
            let made = 0;
            if (have_id) {
                made = store.take_id(want_id, want_title, want_qty);
                if (made < 0) {
                    r_blen = conflict_body(want_id);
                    answer(fd, 409);
                    return;
                }
            } else {
                made = store.take(want_title, want_qty);
                if (made < 0) {
                    r_blen = full_body();
                    answer(fd, 507);
                    return;
                }
            };
            if (want_done) { store.set_done(made, true); };
            r_code = 201;
            r_loc = "/items/" + tostring(made);
            r_blen = item_at(store.find(made));
            answer(fd, 201);
        } else {
            r_blen = no_method_body(ALLOW_COLLECTION);
            answer(fd, 405);
        };
        return;
    };
    // one item
    if (m_code == M_GET) {
        let at0 = store.find(id);
        if (at0 < 0) {
            r_blen = missing_item_body();
            answer(fd, 404);
        } else {
            r_code = 200;
            r_blen = item_at(at0);
            answer(fd, 200);
        }
    } else if (m_code == M_PUT) {
        if (!parse_body()) {
            r_blen = bad_body_body(body_bad);
            answer(fd, 400);
            return;
        };
        if (store.put(id, want_title, want_qty) < 0) {
            r_blen = missing_item_body();
            answer(fd, 404);
            return;
        };
        if (want_done) { store.set_done(id, true); };
        r_code = 200;
        r_blen = item_at(store.find(id));
        answer(fd, 200);
    } else if (m_code == M_DEL) {
        if (!store.drop(id)) {
            r_blen = missing_item_body();
            answer(fd, 404);
            return;
        };
        // 204: no body, no type, no Content-Length worth trusting -- it
        // is sent as 0 and that is what the client counts
        r_code = 204;
        r_blen = 0;
        answer(fd, 204);
    } else {
        r_blen = no_method_body(ALLOW_ITEM);
        answer(fd, 405);
    }
};

// ── reading the request ───────────────────────────────────────────────

def lower(c: long) -> long {
    if (c >= 65 && c <= 90) { c + 32 } else { c }
};

// where the CRLFCRLF is in rbuf[0:have], plus 4, or -1
def find_head(have: long) -> long {
    let i = 0;
    let e = 0 - 1;
    while (i < have - 3 && e < 0) {
        if (rbuf[i] == 13 && rbuf[i + 1] == 10 && rbuf[i + 2] == 13 && rbuf[i + 3] == 10) {
            e = i + 4;
        } else {
            i = i + 1;
        }
    };
    e
};

// Is the header name at `at` content-length, case-insensitively? Header
// names are case-insensitive (RFC 9110 5.1) and a server that is not
// will read a body's length from a client that does not care.
def is_cl(at: long) -> bool {
    let w = "content-length";
    let same = true;
    let i = 0;
    while (i < 14) {
        if (lower(rbuf[at + i]) != w[i]) { same = false; };
        i = i + 1;
    };
    same
};

// The digits from at to stop, or -1 if there are none. Leading spaces and
// tabs are optional whitespace in a header value (RFC 9110 5.5) and the
// client sends exactly one after the colon -- reading the digits from the
// colon itself finds none, returns -1, and the caller's "a negative
// Content-Length is really zero" guard turns every body into an empty one.
def num_at(stop: long, at: long) -> long {
    while (at < stop && (rbuf[at] == 32 || rbuf[at] == 9)) { at = at + 1; };
    let v = 0;
    let n = 0;
    let i = at;
    while (i < stop && rbuf[i] >= 48 && rbuf[i] <= 57) {
        v = v * 10 + (rbuf[i] - 48);
        n = n + 1;
        i = i + 1;
    };
    if (n == 0) { 0 - 1 } else { v }
};

// METHOD SP TARGET SP HTTP/x.y, then the head's Content-Length.
def parse_head() -> bool {
    clen = 0;
    let stop = 0;
    while (stop < head_end && rbuf[stop] != 13) { stop = stop + 1; };
    let sp1 = 0 - 1;
    let sp2 = 0 - 1;
    let i = 0;
    while (i < stop && sp2 < 0) {
        if (rbuf[i] == 32) {
            if (sp1 < 0) { sp1 = i; } else { sp2 = i; };
        };
        i = i + 1;
    };
    if (sp1 < 0 || sp2 < 0 || sp1 == 0 || sp2 <= sp1 + 1) { return false; };
    let ml = sp1;
    let ver = sp2 + 1;
    if (stop - ver < 8) { return false; };
    if (rbuf[ver] != 72 || rbuf[ver + 1] != 84 || rbuf[ver + 2] != 84 || rbuf[ver + 3] != 80) {
        return false;
    };
    if (ml == 3 && rbuf[0] == 71 && rbuf[1] == 69 && rbuf[2] == 84) { m_code = M_GET; }
    else if (ml == 4 && rbuf[0] == 80 && rbuf[1] == 79 && rbuf[2] == 83 && rbuf[3] == 84) { m_code = M_POST; }
    else if (ml == 3 && rbuf[0] == 80 && rbuf[1] == 85 && rbuf[2] == 84) { m_code = M_PUT; }
    else if (ml == 6 && rbuf[0] == 68 && rbuf[1] == 69 && rbuf[2] == 76 &&
             rbuf[3] == 69 && rbuf[4] == 84 && rbuf[5] == 69) { m_code = M_DEL; }
    else { m_code = M_OTHER; };
    path_at = sp1 + 1;
    // the target ends where the space before HTTP/x.y is, so its length is
    // sp2 - path_at -- NOT stop - sp2 - 1, which measures from the CR at the
    // end of the request line and so yields len("HTTP/1.1") + 1 for every
    // request. That mistake made "/items" read as "/items SP" and sent every
    // collection request down the item branch, where the space is not a
    // slash and the answer is a 404 for a route that does exist.
    path_len = sp2 - path_at;
    // strip the query string: the routes ignore it, but it must not end
    // up inside the path an error body quotes back
    let q = 0;
    while (q < path_len) {
        if (rbuf[path_at + q] == 63) { path_len = q; q = path_len; } else { q = q + 1; };
    };
    // the header lines, each name ':' value CRLF, up to the blank line.
    // The scan starts just past the request line's own LF -- NOT at
    // head_end, which is four bytes *past* the last line and therefore
    // already at (or beyond) lines_end, so `while (h < lines_end)` never
    // ran once and every Content-Length came out 0. Every request with a
    // body was then read as an empty one, and every POST answered 400.
    let h = stop + 2;
    let lines_end = head_end - 4;
    while (h < lines_end) {
        let eol = h;
        while (eol < lines_end && rbuf[eol] != 13) { eol = eol + 1; };
        let colon = 0 - 1;
        let k = h;
        while (k < eol && colon < 0) {
            if (rbuf[k] == 58) { colon = k; };
            k = k + 1;
        };
        if (colon > h && colon - h == 14 && is_cl(h)) { clen = num_at(eol, colon + 1); };
        h = eol + 2;
    };
    true
};

// read one request and answer it. got <= 0 means the peer closed without
// saying anything, which is not an error to report to nobody.
def serve_one(fd: long) {
    got = 0;
    head_end = 0 - 1;
    let reading = true;
    while (reading && got < MAX_HEAD) {
        let k = syscall(0, fd, &rbuf[got], MAX_HEAD - got);
        if (k <= 0) { reading = false; } else {
            got = got + k;
            head_end = find_head(got);
            if (head_end >= 0) { reading = false; };
        }
    };
    if (got <= 0) { return; };
    if (head_end < 0) {
        r_blen = head_too_long_body();
        answer(fd, 431);
        return;
    };
    if (!parse_head()) {
        r_blen = bad_line_body();
        answer(fd, 400);
        return;
    };
    if (clen < 0) { clen = 0; };
    if (clen > MAX_BODY) {
        r_blen = body_too_long_body();
        answer(fd, 413);
        return;
    };
    body_at = head_end;
    // the body is the rest of the stream, and it may already be in rbuf
    let want = body_at + clen;
    while (got < want) {
        let k = syscall(0, fd, &rbuf[got], want - got);
        if (k <= 0) { want = got; } else { got = got + k; };
    };
    body_len = clen;
    route(fd);
};

// ── the loop, and the fork that owns it ───────────────────────────────

let ppid = 0;
let go = true;

// The accept loop, in the foreground of whatever process calls it. One
// request per connection, then the connection is closed (the std client
// sends `Connection: close` for a one-shot request), which is why nothing
// here has to remember a client between requests.
def serve() -> long {
    ppid = syscall(110, 0);        // getppid, see below
    while (go) {
        let c = net.accept_tcp(lfd);
        if (c < 0) {
            go = false;
        } else {
            serve_one(c);
            net.close_fd(c);
            // If the process that forked us is gone the kernel reparents
            // us to init and nobody is left to SIGTERM us -- so leave,
            // rather than become a server for ever on a shared box.
            if (syscall(110, 0) != ppid) { go = false; };
        }
    };
    0
};

// bind 127.0.0.1:0 and listen in the parent, so the port is known before
// the fork; then fork a child to accept on the socket it inherited.
// 0 means it could not start, with start_err saying why.
def start() -> long {
    start_err = 0;
    port = 0;
    pid = 0;
    store.reset();
    let fd = net.socket_tcp();
    if (fd < 0) {
        start_err = fd;
        return 0;
    };
    sa[0] = 2;                 // AF_INET
    sa[1] = 0;
    sa[2] = 0;                 // the port is big endian in sa[2], sa[3]
    sa[3] = 0;
    sa[4] = 127;               // loopback only: this is a loopback example
    sa[5] = 0;
    sa[6] = 0;
    sa[7] = 1;
    if (syscall(49, fd, &sa[0], 16) < 0) {
        start_err = 0 - 98;
        net.close_fd(fd);
        return 0;
    };
    if (net.listen_fd(fd, 64) < 0) {
        start_err = 0 - 98;
        net.close_fd(fd);
        return 0;
    };
    port = net.local_port(fd);
    if (port <= 0) {
        start_err = 0 - 99;
        net.close_fd(fd);
        return 0;
    };
    lfd = fd;
    go = true;
    pid = fork { serve() };
    if (pid < 0) {
        start_err = pid;
        net.close_fd(fd);
        port = 0;
    };
    port
};

// The only way out of a process nothing can interrupt: Y has no signal
// handlers, so the kernel is asked directly. SIGTERM is 15 and the child's
// answer is 128 + 15 = 143 through wait_pid -- which is how a caller tells
// a server that was stopped from one that crashed.
def stop() -> long {
    if (pid <= 0) {
        child_status = 0 - 1;
    } else {
        syscall(62, pid, 15);
        child_status = wait_pid(pid);
    };
    child_status
};

export {
    CAP, BODY_AT, MAX_HEAD, MAX_BODY, ALLOW_COLLECTION, ALLOW_ITEM,
    M_GET, M_POST, M_PUT, M_DEL, M_OTHER,
    port, pid, start_err, child_status, served, by_code,
    lfd, go, r_code, r_blen, start, stop, serve, serve_one, reason_of
};
