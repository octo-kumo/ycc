// wxsrv.y -- the local forecast service: routing, framing, and the accept
// loop that runs in a forked child.
//
// ── why the loop is here and not net.listen_http ────────────────────────
//
// net.listen_http(port, handler) binds the port itself, so it cannot serve
// on a port the kernel picked for us. This example wants port 0 (bind, then
// net.local_port) so two copies of it never collide and so the report has
// no port number in it at all -- a printed port would make EXPECTED depend
// on the machine. The fix is to keep the socket the child inherits and drive
// the accept loop here, over the primitives net already exports:
// accept_tcp / http_read_head / send_str / close_fd. Same behaviour, same
// error checking, and the port is ours.
//
// The child is killed with syscall(62, pid, 15) when the parent is done;
// it then reports 143. There is no shutdown path in listen_http and there
// never can be one, so this is the shape to use (ORCHESTRATOR.md 2.13).
//
// ── why the framing is hand-built ───────────────────────────────────────
//
// net.http_response hard-codes Content-Length and knows only the reason
// phrases for 200/404/500, printing "Status" for anything else. This
// service has to return a real "400 Bad Request" and it has to exercise
// chunked framing too, so the response head is written here.

import net;
import json;
import wxdata;

type Req = { ok: bool, method: str, path: str, city: str, err: str };
type Reply = { status: long, reason: str, body: str, chunked: bool, hdrs: str };

const CHUNK = 64;         // bytes per chunk in the chunked reply
const MAXCITY = 32;       // longest slug the query grammar admits

// ── request parsing ─────────────────────────────────────────────────────

def hexval(c: long) -> long {
    if (c >= 48 && c <= 57) { c - 48 }
    else if (c >= 97 && c <= 102) { c - 87 }
    else if (c >= 65 && c <= 70) { c - 55 }
    else { 0 - 1 }
};

// %XX and '+'. A malformed escape is NOT silently passed through: it makes
// the value fail the slug grammar below, which is how it becomes a 400
// instead of a 404 for a typo the client should hear about.
def pct_decode(s: str) -> str {
    let out = "";
    let i = 0;
    let go = true;
    while (go) {
        if (i < s.length) {
            let c = ord(s[i:i + 1]);
            if (c == 37 && i + 2 < s.length) {
                let hi = hexval(ord(s[i + 1:i + 2]));
                let lo = hexval(ord(s[i + 2:i + 3]));
                if (hi < 0 || lo < 0) {
                    out += "%";                       // keep it, let the grammar object
                    i = i + 1;
                } else {
                    out += chr(hi * 16 + lo);
                    i = i + 3;
                };
            } else if (c == 43) {
                out += " ";
                i = i + 1;
            } else {
                out += s[i:i + 1];
                i = i + 1;
            };
        } else { go = false };
    };
    out
};

// The query grammar: a slug is 1..32 bytes of [a-z0-9_-]. Anything else --
// an empty value, a space, a percent sign, a dot, an upper-case letter, a
// slash -- is a MALFORMED QUERY, which is a 400. A well-formed slug that
// names nothing is a 404. The two are different failures and --check
// asserts that they stay different.
def slug_ok(s: str) -> bool {
    if (s.length == 0 || s.length > MAXCITY) { return false };
    let ok = true;
    let i = 0;
    while (i < s.length) {
        let c = ord(s[i:i + 1]);
        if (c >= 97 && c <= 122 || c >= 48 && c <= 57 || c == 45 || c == 95) { }
        else { ok = false };
        i = i + 1;
    };
    ok
};

def param(query: str, key: str) -> str {
    let out = "";
    let found = false;
    if (query.length > 0) {
        let parts = query.split("&");
        let i = 0;
        while (i < parts.length && !found) {
            let bits = parts[i].split("=");
            if (bits.length > 0 && bits[0] == key) {
                out = bits.length > 1 ? pct_decode(bits[1]) : "";
                found = true;
            };
            i = i + 1;
        };
    };
    out
};

def has_param(query: str, key: str) -> bool {
    let found = false;
    if (query.length > 0) {
        let parts = query.split("&");
        let i = 0;
        while (i < parts.length && !found) {
            let bits = parts[i].split("=");
            if (bits.length > 0 && bits[0] == key) { found = true };
            i = i + 1;
        };
    };
    found
};

def parse_request(head: str) -> Req {
    let bad: Req = { ok: false, method: "", path: "", city: "", err: "" };
    let first = head;
    let cut = index_of(head, "\r\n");
    if (cut >= 0) { first = head[0:cut] };
    let bits = first.split(" ");
    if (bits.length < 2) {
        bad.err = "the request line needs a method and a target";
        return bad;
    };
    let target = bits[1];
    let qmark = index_of(target, "?");
    let path = target;
    let query = "";
    if (qmark >= 0) {
        path = target[0:qmark];
        query = target[qmark + 1:target.length];
    };
    { ok: true, method: bits[0], path: path, city: param(query, "city"), err: "" }
};

// ── replies ─────────────────────────────────────────────────────────────
//
// Three failure kinds, three builders, so the client can be tested against
// all of them: a transport-level reply, a JSON error body, and a
// chunk-framed body.

def say(status: long, reason: str, body: str) -> Reply {
    { status: status, reason: reason, body: body, chunked: false, hdrs: "" }
};

def say_chunked(status: long, reason: str, body: str) -> Reply {
    { status: status, reason: reason, body: body, chunked: true, hdrs: "" }
};

def err_reply(status: long, reason: str, code: str, msg: str) -> Reply {
    let tree = wxdata.error_tree(code, msg);
    say(status, reason, json.emit(tree))
};

def hex2(v: long) -> str {
    let out = "";
    out += hexdig((v >> 4) & 15);
    out += hexdig(v & 15);
    out
};

def hexdig(v: long) -> str {
    if (v < 10) { chr(48 + v) } else { chr(87 + v) }
};

// The full response, head plus body. Content-Length is computed from
// len(body) rather than carried in the reply, so it cannot drift from the
// bytes that follow -- the property --check asserts the header equals the
// byte count the client actually received.
def response_text(r: Reply) -> str {
    let head = "HTTP/1.1 " + tostring(r.status) + " " + r.reason + "\r\n"
             + "Content-Type: application/json; charset=utf-8\r\n"
             + r.hdrs;
    if (r.chunked) {
        let out = head + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
        let body = r.body;
        let at = 0;
        while (at < body.length) {
            let hi = at + CHUNK;
            let stop = hi < body.length ? hi : body.length;
            out += hex2(stop - at) + "\r\n" + body[at:stop] + "\r\n";
            at = stop;
        };
        out + "0\r\n\r\n"
    } else {
        head + "Content-Length: " + tostring(len(r.body)) + "\r\nConnection: close\r\n\r\n" + r.body
    }
};

// ── routing ─────────────────────────────────────────────────────────────

def route(head: str) -> Reply {
    let r = parse_request(head);
    if (!r.ok) { return err_reply(400, "Bad Request", "bad_request", r.err) };
    if (r.method != "GET") {
        let e = err_reply(405, "Method Not Allowed", "method_not_allowed",
                          "this service only answers GET");
        return { status: 405, reason: "Method Not Allowed", body: e.body,
                 chunked: false, hdrs: "Allow: GET\r\n" };
    };
    if (r.path == "/v1/locations") {
        return say_chunked(200, "OK", json.emit(wxdata.locations_tree(wxdata.places())));
    };
    if (r.path == "/v1/broken") {
        // 200 with a truncated document, so the client's PARSE-failure path
        // is reachable over the wire. Without this the client would only
        // ever be tested against a transport error, and a client that
        // parses without checking would pass.
        return say(200, "OK", wxdata.BROKEN);
    };
    if (r.path == "/v1/wrong-schema") {
        // 200 with a document that parses and is still not ours. The parse
        // cannot catch this one, so it is the client's own refusal that has
        // to -- the case where "never a partially-filled report" is really
        // tested, rather than tested by accident.
        return say(200, "OK", wxdata.WRONG_SCHEMA);
    };
    if (r.path != "/v1/forecast") {
        return err_reply(404, "Not Found", "not_found",
                         "no such resource: " + r.path);
    };
    if (!has_param(query_of(head), "city")) {
        return err_reply(400, "Bad Request", "bad_request",
                         "the city parameter is required");
    };
    let city = r.city;
    if (!slug_ok(city)) {
        return err_reply(400, "Bad Request", "bad_query",
                         "a city slug is 1 to " + tostring(MAXCITY)
                         + " characters of a-z, 0-9, '-' or '_'");
    };
    let p = wxdata.find(city);
    if (is_some(p) == false) {
        return err_reply(404, "Not Found", "not_found",
                         "no location matches '" + city + "'");
    };
    say(200, "OK", json.emit(wxdata.forecast_tree(unwrap(p))))
};

// The query string of the request line, for the one check route() needs
// that Req does not carry (was a city parameter present at all).
def query_of(head: str) -> str {
    let first = head;
    let cut = index_of(head, "\r\n");
    if (cut >= 0) { first = head[0:cut] };
    let bits = first.split(" ");
    if (bits.length < 2) { return "" };
    let target = bits[1];
    let qmark = index_of(target, "?");
    if (qmark < 0) { return "" };
    target[qmark + 1:target.length]
};

// ── the accept loop, run in a forked child ──────────────────────────────

def serve_forever(lfd: long) -> long {
    let go = true;
    while (go) {
        let c = net.accept_tcp(lfd);
        if (c >= 0) {
            let reply = route(net.http_read_head(c));
            net.send_str(c, response_text(reply));
            net.close_fd(c);
        } else {
            go = false;
        };
    };
    0
};

export { CHUNK, MAXCITY, Req, Reply, pct_decode, slug_ok, param, has_param,
         parse_request, say, err_reply, hex2, response_text, route, query_of,
         serve_forever };
