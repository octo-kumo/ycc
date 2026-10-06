// std/http.y — an HTTP/1.1 client over std/net and std/tls, in plain Y.
//
//     import http;
//     let res = http.get("https://example.com/");
//     print(res.status, " ", res.headers["content-type"]);
//     print(res.text());
//
//     let r = http.post("https://api.example.com/items", "{\"a\": 1}",
//                       { headers: {"Content-Type": "application/json"} });
//
// Many requests that look alike go through a session: a base URL and
// headers for every request, connections kept open and used again, the
// cookies the server sets sent back:
//
//     let s = http.session({ base: "https://api.example.com",
//                            headers: {"Authorization": "Bearer t0ken"} });
//     let users = s.get("/users");
//     let made = s.post("/users", "{\"name\": \"ann\"}");
//     s.close();
//
// A response is a record: status (0 when none came; err says why), its
// reason, headers (names in lower case; a repeated one's values joined by
// ", ", Set-Cookie's by newlines), size (Content-Length, or -1), url (after
// redirects), and two functions that read the body: read(n) -- up to n
// bytes, all of it for n <= 0 -- and text(). The body arrives as it is
// read: by Content-Length, chunked, or up to the close. It is kept, so a
// read that comes after the body has ended is answered from it: read(n)
// twice gives the same bytes twice and text() twice the same text, and []
// is only ever a body that was empty (a 204, a HEAD). Redirects are
// followed (5 by default: `redirects` in the options); https URLs verify
// the server (std/tls), `insecure: true` skips the chain.
import net;
import tls;

type Response = {
    status: long, reason: str, headers: {str => str}, size: long, url: str, err: str,
    read: (long) -> [byte], text: () -> str
};

// A request's options; every field may be left out.
type Opts = {
    headers?: {str => str}, body?: str, timeout?: long, redirects?: long,
    insecure?: bool, anchors?: str
};

// A connection: plain (fd) or TLS (tc), and the bytes read but not used.
type Link = {
    key: str, fd: long, tc: tls.Conn?, buf: [byte], err: str, eof: bool, busy: bool
};

// A body's framing and how far it has come: mode "none", "length" (left
// bytes to go), "chunked" (left in this chunk; at 0 a size line is next)
// or "close" (up to the end). `buf` is everything read so far, kept so a
// read that arrives after the body has ended can be answered from it
// (see body_replay): the body is a value, and reading it twice must not
// hand back nothing the second time.
type Body = { link: Link, mode: str, left: long, done: bool, buf: [byte] };

// A URL taken apart; ok false for one this client cannot reach.
type Url = { ok: bool, secure: bool, host: str, port: long, path: str };

// ── URLs ────────────────────────────────────────────────────────────────

def parse_url(u: str) -> Url {
    let bad: Url = { ok: false, secure: false, host: "", port: 0, path: "" };
    let secure = false;
    let rest = "";
    if (u.starts_with("https://")) {
        secure = true;
        rest = u[8:len(u)];
    } else if (u.starts_with("http://")) {
        rest = u[7:len(u)];
    } else { return bad; };
    let slash = index_of(rest, "/");
    let q = index_of(rest, "?");
    if (q >= 0 && (slash < 0 || q < slash)) { slash = q; };
    let hostport = rest;
    let path = "/";
    if (slash >= 0) {
        hostport = rest[0:slash];
        path = rest[slash:len(rest)];
        if (path.starts_with("?")) { path = "/" + path; };
    };
    let hash = index_of(path, "#");
    if (hash >= 0) { path = path[0:hash]; };
    let host = hostport;
    let port = 80;
    if (secure) { port = 443; };
    let colon = last_index_of(hostport, ":");
    if (colon >= 0) {
        host = hostport[0:colon];
        // A port that is not a number is a bad URL, not port 0.
        let pn = tolong(hostport[colon + 1:len(hostport)]);
        if (pn == none) { return bad; };
        port = pn!;
    };
    if (len(host) == 0 || port <= 0 || port > 65535) { return bad; };
    { ok: true, secure: secure, host: host.lower(), port: port, path: path }
};

def origin(u: Url) -> str {
    let scheme = "http://";
    if (u.secure) { scheme = "https://"; };
    scheme + u.host + ":" + tostring(u.port)
};

// The URL a reference (a redirect's Location, a session's path) names
// from base: absolute, scheme-relative, rooted or relative.
def resolve_ref(base: str, ref: str) -> str {
    if (ref.starts_with("http://") || ref.starts_with("https://")) { return ref; };
    let b = parse_url(base);
    if (!b.ok) { return ref; };
    let scheme = "http:";
    if (b.secure) { scheme = "https:"; };
    if (ref.starts_with("//")) { return scheme + ref; };
    let root = scheme + "//" + b.host;
    if ((b.secure && b.port != 443) || (!b.secure && b.port != 80)) { root = root + ":" + tostring(b.port); };
    if (ref.starts_with("/")) { return root + ref; };
    let dir = b.path;
    let q = index_of(dir, "?");
    if (q >= 0) { dir = dir[0:q]; };
    dir = dir[0:last_index_of(dir, "/") + 1];
    root + dir + ref
};

// ── connections ─────────────────────────────────────────────────────────

def link_open(u: Url, o: Opts) -> Link {
    let none_tc: tls.Conn? = none;
    let l: Link = { key: origin(u), fd: -1, tc: none_tc, buf: [], err: "", eof: false, busy: false };
    let secs = 30;
    if (o.timeout != none) { secs = o.timeout!; };
    if (u.secure) {
        let c = tls.connect_with(u.host, u.port, { anchors: o.anchors, insecure: o.insecure, alpn: "http/1.1", timeout: secs });
        if (c.err != "") { l.err = c.err; } else { l.tc = some(c); };
    } else {
        let fd = net.connect_tcp(u.host, u.port);
        if (fd < 0) { l.err = "cannot connect to " + u.host + ":" + tostring(u.port); } else {
            net.set_timeouts(fd, secs);
            l.fd = fd;
        };
    };
    l
};

def link_send(l: Link, data: [byte]) -> bool {
    if (l.err != "") { return false; };
    if (l.tc != none) {
        let c = l.tc!;
        if (!tls.send(c, data)) {
            l.err = c.err;
            return false;
        };
        return true;
    };
    let off = 0;
    while (off < len(data)) {
        let k = os_call("y_os_write", l.fd, &data[off], len(data) - off);
        if (k <= 0) {
            l.err = "the connection broke while sending";
            return false;
        };
        off = off + k;
    };
    true
};

// More bytes into l.buf; false at the end or on an error.
def link_fill(l: Link) -> bool {
    if (l.eof || l.err != "") { return false; };
    if (l.tc != none) {
        let c = l.tc!;
        let got = tls.recv(c);
        if (got == none) {
            if (c.err != "") { l.err = c.err; } else { l.eof = true; };
            return false;
        };
        l.buf += got!;
        return true;
    };
    let chunk: [byte; 16384] = [0; 16384];
    let k = os_call("y_os_read", l.fd, &chunk[0], 16384);
    if (k == 0) {
        l.eof = true;
        return false;
    };
    if (k < 0) {
        l.err = "the connection broke (" + tostring(-k) + ")";
        return false;
    };
    l.buf += chunk[0:k];
    true
};

// Up to n bytes from the link (what is buffered, else one read's worth).
def link_take(l: Link, n: long) -> [byte] {
    if (len(l.buf) == 0) { link_fill(l); };
    let k = n;
    if (k > len(l.buf)) { k = len(l.buf); };
    let out = l.buf[0:k];
    l.buf = l.buf[k:len(l.buf)];
    out
};

// The next line (without its CRLF), none at the end.
def link_line(l: Link) -> str? {
    let at = crlf_at(l.buf);
    while (at < 0) {
        if (len(l.buf) > 65536 || !link_fill(l)) { return none; };
        at = crlf_at(l.buf);
    };
    let line = from_bytes(l.buf[0:at]);
    l.buf = l.buf[at + 2:len(l.buf)];
    some(line)
};

def crlf_at(b: [byte]) -> long {
    let i = 0;
    while (i + 1 < len(b)) {
        if (b[i] == 13 && b[i + 1] == 10) { return i; };
        i = i + 1;
    };
    -1
};

def link_close(l: Link) {
    if (l.tc != none) { tls.close(l.tc!); };
    if (l.fd >= 0) { net.close_fd(l.fd); };
    l.fd = -1;
    let none_tc: tls.Conn? = none;
    l.tc = none_tc;
    l.eof = true;
};

// ── bodies ──────────────────────────────────────────────────────────────

// Up to want bytes of the body (want <= 0: all of the rest).
def body_take(b: Body, want: long) -> [byte] {
    let out: [byte] = [];
    let all = want <= 0;
    while (!b.done && (all || len(out) < want)) {
        let need = want - len(out);
        if (all) { need = 65536; };
        if (b.mode == "none") {
            b.done = true;
        } else if (b.mode == "close") {
            let got = link_take(b.link, need);
            if (len(got) == 0) { b.done = true; } else { out += got; };
        } else if (b.mode == "length") {
            if (b.left <= 0) { b.done = true; } else {
                if (need > b.left) { need = b.left; };
                let got = link_take(b.link, need);
                if (len(got) == 0) {
                    b.done = true;
                    b.link.err = "the body ended early";
                } else {
                    out += got;
                    b.left = b.left - len(got);
                };
            };
        } else {
            // chunked: a size line, the chunk, its CRLF; a 0 ends it
            if (b.left <= 0) {
                let line = link_line(b.link);
                if (line == none) {
                    b.done = true;
                    b.link.err = "the body ended early";
                } else {
                    let size = hex_size(line!);
                    if (size <= 0) {
                        // trailers up to an empty line
                        let t = link_line(b.link);
                        while (t != none && t! != "") { t = link_line(b.link); };
                        b.done = true;
                    } else { b.left = size; };
                };
            } else {
                if (need > b.left) { need = b.left; };
                let got = link_take(b.link, need);
                if (len(got) == 0) {
                    b.done = true;
                    b.link.err = "the body ended early";
                } else {
                    out += got;
                    b.left = b.left - len(got);
                    if (b.left == 0) { link_line(b.link); };
                };
            };
        };
    };
    out
};

// The first n bytes of the body so far, all of it for n <= 0 or an n past
// its end -- so a read is repeatable: read(n) twice gives the same bytes
// twice and text() twice the same text.
def body_replay(buf: [byte], n: long) -> [byte] {
    if (n <= 0 || n >= len(buf)) {
        buf
    } else {
        let out: [byte] = [];
        let i = 0;
        while (i < n) {
            out += buf[i];
            i = i + 1;
        };
        out
    }
};

// A chunk size line's number (hex, before any `;` extension); -1 if none.
def hex_size(s: str) -> long {
    let v = 0;
    let n = 0;
    let i = 0;
    while (i < len(s)) {
        let c = s[i];
        let d = -1;
        if (c >= '0' && c <= '9') { d = c - '0'; }
        else if (c >= 'a' && c <= 'f') { d = c - 'a' + 10; }
        else if (c >= 'A' && c <= 'F') { d = c - 'A' + 10; };
        if (d < 0) { i = len(s); } else {
            v = v * 16 + d;
            n = n + 1;
            i = i + 1;
        };
    };
    if (n == 0) { -1 } else { v }
};

// ── requests ────────────────────────────────────────────────────────────

def no_body() -> Response {
    let h: {str => str} = {};
    let read = def (n: long) -> [byte] {
        let none_b: [byte] = [];
        none_b
    };
    let text = def () -> str { "" };
    { status: 0, reason: "", headers: h, size: -1, url: "", err: "", read: read, text: text }
};

def failed(url: str, why: str) -> Response {
    let r = no_body();
    r.url = url;
    r.err = why;
    r
};

// The request's bytes: its line, the headers (ours, then the caller's,
// which replace ours of the same name), the body.
def request_bytes(method: str, u: Url, hdrs: {str => str}, body: str, keep: bool) -> [byte] {
    let mine: {str => str} = {};
    let hostv = u.host;
    if ((u.secure && u.port != 443) || (!u.secure && u.port != 80)) { hostv = hostv + ":" + tostring(u.port); };
    mine["host"] = hostv;
    mine["user-agent"] = "y-http/1";
    mine["accept"] = "*/*";
    if (keep) { mine["connection"] = "keep-alive"; } else { mine["connection"] = "close"; };
    if (len(body) > 0 || method == "POST" || method == "PUT" || method == "PATCH") {
        mine["content-length"] = tostring(len(body));
    };
    let names: {str => str} = {};
    foreach (k in keys(hdrs)) { names[k.lower()] = k; };
    let head = method + " " + u.path + " HTTP/1.1\r\n";
    foreach (k in keys(mine)) {
        if (names[k] == none) { head = head + k + ": " + mine[k]! + "\r\n"; };
    };
    foreach (k in keys(hdrs)) { head = head + k + ": " + hdrs[k]! + "\r\n"; };
    head = head + "\r\n";
    let out = bytes(head);
    out += bytes(body);
    out
};

// A response's head: its status, reason and headers; ok false (err) when
// none could be read.
type Head = { ok: bool, err: str, status: long, reason: str, headers: {str => str} };

def read_head(l: Link) -> Head {
    let headers: {str => str} = {};
    let bad: Head = { ok: false, err: "", status: 0, reason: "", headers: headers };
    let status_line = link_line(l);
    while (status_line != none && status_line! == "") { status_line = link_line(l); };
    if (status_line == none) {
        bad.err = l.err;
        if (bad.err == "") { bad.err = "the server closed the connection without a response"; };
        return bad;
    };
    let sl = status_line!;
    let parts = sl.split(" ");
    if (len(parts) < 2 || !parts[0].starts_with("HTTP/1.")) {
        bad.err = "not an HTTP response: " + sl;
        return bad;
    };
    let reason = "";
    if (len(parts) > 2) { reason = join(parts[2:len(parts)], " "); };
    let line = link_line(l);
    while (line != none && line! != "") {
        let hl = line!;
        let colon = index_of(hl, ":");
        if (colon > 0) {
            let name = hl[0:colon].trim().lower();
            let value = hl[colon + 1:len(hl)].trim();
            if (headers[name] == none) { headers[name] = value; }
            else if (name == "set-cookie") { headers[name] = headers[name]! + "\n" + value; }
            else { headers[name] = headers[name]! + ", " + value; };
        };
        line = link_line(l);
    };
    if (line == none) {
        bad.err = "the response head ended early";
        return bad;
    };
    let st = tolong(parts[1]);
    if (st == none) { return bad; };
    { ok: true, err: "", status: st!, reason: reason, headers: headers }
};

// Send the request on l and read the response's head (past any interim
// 1xx one); the body stays on the link for read() and text().
def exchange(l: Link, method: str, url: str, u: Url, hdrs: {str => str}, body: str, keep: bool) -> Response {
    if (!link_send(l, request_bytes(method, u, hdrs, body, keep))) { return failed(url, l.err); };
    let h = read_head(l);
    while (h.ok && h.status >= 100 && h.status < 200) { h = read_head(l); };
    if (!h.ok) { return failed(url, h.err); };
    let headers = h.headers;
    let size = -1;
    if (headers["content-length"] != none) {
        let cl = tolong(headers["content-length"]!);
        if (cl != none) { size = cl!; };
    };
    let mode = "close";
    let te = "";
    if (headers["transfer-encoding"] != none) { te = headers["transfer-encoding"]!.lower(); };
    if (method == "HEAD" || h.status == 204 || h.status == 304) { mode = "none"; }
    else if (index_of(te, "chunked") >= 0) { mode = "chunked"; }
    else if (size >= 0) { mode = "length"; };
    let b: Body = { link: l, mode: mode, left: size, done: false, buf: [] };
    if (mode == "chunked") { b.left = 0; };
    // the server will close after this response: the link is not used again
    let ends = false;
    if (headers["connection"] != none && index_of(headers["connection"]!.lower(), "close") >= 0) { ends = true; };
    if (mode == "none") { b.done = true; } else { l.busy = true; };
    if (ends && mode == "none") { link_close(l); };
    // The body is buffered, not a stream: a read is answered from what has
    // come, and only reaches for the link when it has to. So read(n) twice
    // gives the same n bytes twice, text() twice the same text, and an
    // empty read means an empty body -- which is not something a caller can
    // tell from a body it has already read and thrown away, the way a
    // drained socket looks.
    let read = def (n: long) -> [byte] {
        if (n <= 0) {
            b.buf += body_take(b, 0);
        } else if (!b.done && len(b.buf) < n) {
            b.buf += body_take(b, n - len(b.buf));
        };
        if (b.done) {
            l.busy = false;
            if (ends) { link_close(l); };
        };
        body_replay(b.buf, n)
    };
    let text = def () -> str { from_bytes(read(0)) };
    { status: h.status, reason: h.reason, headers: headers, size: size, url: url, err: "", read: read, text: text }
};

// One request, its redirects followed: on links from `pool` (a session's
// open connections, by origin; none for a one-shot request).
def fetch(method: str, url: str, o: Opts, extra: {str => str}, pool: [Link], keep: bool, jar: {str => str}) -> Response {
    let base_hdrs: {str => str} = {};
    foreach (k in keys(extra)) { base_hdrs[k] = extra[k]!; };
    if (o.headers != none) {
        let oh = o.headers!;
        foreach (k in keys(oh)) { base_hdrs[k] = oh[k]!; };
    };
    let body = "";
    if (o.body != none) { body = o.body!; };
    let hops = 5;
    if (o.redirects != none) { hops = o.redirects!; };
    let cur = url;
    let m = method;
    while (true) {
        let u = parse_url(cur);
        if (!u.ok) { return failed(cur, "not an http or https URL: " + cur); };
        let hdrs: {str => str} = {};
        foreach (k in keys(base_hdrs)) { hdrs[k] = base_hdrs[k]!; };
        let ck = cookie_header(jar, u.host);
        if (ck != "") { hdrs["Cookie"] = ck; };
        let l = pick_link(pool, u, o, keep);
        if (l.err != "") { return failed(cur, l.err); };
        let r = exchange(l, m, cur, u, hdrs, body, keep);
        if (r.status == 0 && keep) {
            // a kept connection the server had closed: once more on a new one
            link_close(l);
            l = pick_link(pool, u, o, keep);
            if (l.err != "") { return failed(cur, l.err); };
            r = exchange(l, m, cur, u, hdrs, body, keep);
        };
        if (r.headers["set-cookie"] != none) { take_cookies(jar, u.host, r.headers["set-cookie"]!); };
        let loc = r.headers["location"];
        let redirect = (r.status == 301 || r.status == 302 || r.status == 303 || r.status == 307 || r.status == 308) && loc != none;
        if (!redirect || hops <= 0) {
            if (!keep) { r = closing(r, l); };
            return r;
        };
        r.read(0);
        if (!keep) { link_close(l); };
        hops = hops - 1;
        cur = resolve_ref(cur, loc!);
        if (r.status == 303 || ((r.status == 301 || r.status == 302) && m == "POST")) {
            m = "GET";
            body = "";
        };
    };
    failed(url, "unreachable")
};

// r with its link closed once the body has been read to its end.
def closing(r: Response, l: Link) -> Response {
    let read0 = r.read;
    let read = def (n: long) -> [byte] {
        let got = read0(n);
        if (!l.busy) { link_close(l); };
        got
    };
    let text = def () -> str { from_bytes(read(0)) };
    if (!l.busy) { link_close(l); };
    { status: r.status, reason: r.reason, headers: r.headers, size: r.size, url: r.url, err: r.err, read: read, text: text }
};

// A connection for u: a free one of the pool to the same origin, else a
// new one (kept in the pool when keep).
def pick_link(pool: [Link], u: Url, o: Opts, keep: bool) -> Link {
    let key = origin(u);
    if (keep) {
        foreach (l in pool) {
            if (l.key == key && !l.busy && !l.eof && l.err == "") { return l; };
        };
    };
    let l = link_open(u, o);
    if (keep && l.err == "") { pool += l; };
    l
};

// ── cookies ─────────────────────────────────────────────────────────────
// A session's jar maps host + " " + name to the value ("" once a server
// expires it). Domain and Path are not looked at: a cookie goes back to
// the host that set it.

def cookie_header(jar: {str => str}, host: str) -> str {
    let parts: [str] = [];
    let pre = host + " ";
    foreach (k in keys(jar)) {
        if (k.starts_with(pre) && jar[k]! != "") { parts += k[len(pre):len(k)] + "=" + jar[k]!; };
    };
    join(parts, "; ")
};

def take_cookies(jar: {str => str}, host: str, lines: str) -> void {
    foreach (line in lines.split("\n")) {
        let attrs = line.split(";");
        let nv = attrs[0];
        let eq = index_of(nv, "=");
        if (eq > 0) {
            let name = nv[0:eq].trim();
            let value = nv[eq + 1:len(nv)].trim();
            let gone = false;
            foreach (a in attrs) {
                let al = a.trim().lower();
                if (al == "max-age=0" || al.starts_with("max-age=-")) { gone = true; };
            };
            if (gone) { value = ""; };
            jar[host + " " + name] = value;
        };
    };
};

// ── sessions ────────────────────────────────────────────────────────────

// Requests that share a base URL (paths resolve against it), headers,
// options, open connections (kept alive, by origin) and cookies.
type Session = {
    get: (str) -> Response, head: (str) -> Response, delete: (str) -> Response,
    post: (str, str) -> Response, put: (str, str) -> Response, patch: (str, str) -> Response,
    request: (str, str, Opts) -> Response, header: (str, str) -> long, close: () -> long
};

type SessionOpts = {
    base?: str, headers?: {str => str}, timeout?: long, redirects?: long,
    insecure?: bool, anchors?: str
};

def session(o?: SessionOpts) -> Session { session_opt(o) };

def session_opt(o: SessionOpts?) -> Session {
    let so: SessionOpts = {};
    if (o != none) { so = o!; };
    let base = "";
    if (so.base != none) { base = so.base!; };
    let defaults: {str => str} = {};
    if (so.headers != none) {
        let sh = so.headers!;
        foreach (k in keys(sh)) { defaults[k] = sh[k]!; };
    };
    let pool: [Link] = [];
    let jar: {str => str} = {};
    let run = def (method: str, path: str, more: Opts) -> Response {
        let url = path;
        if (base != "") { url = resolve_ref(base, path); };
        let opts: Opts = {
            headers: more.headers, body: more.body, timeout: so.timeout, redirects: so.redirects,
            insecure: so.insecure, anchors: so.anchors
        };
        if (more.timeout != none) { opts.timeout = more.timeout; };
        if (more.redirects != none) { opts.redirects = more.redirects; };
        fetch(method.upper(), url, opts, defaults, pool, true, jar)
    };
    let plain: Opts = {};
    let get = def (path: str) -> Response { run("GET", path, plain) };
    let head = def (path: str) -> Response { run("HEAD", path, plain) };
    let delete = def (path: str) -> Response { run("DELETE", path, plain) };
    let post = def (path: str, body: str) -> Response { run("POST", path, { body: body }) };
    let put = def (path: str, body: str) -> Response { run("PUT", path, { body: body }) };
    let patch = def (path: str, body: str) -> Response { run("PATCH", path, { body: body }) };
    let request = def (method: str, path: str, more: Opts) -> Response { run(method, path, more) };
    let header = def (name: str, value: str) -> long {
        defaults[name] = value;
        0
    };
    let close = def () -> long {
        foreach (l in pool) { link_close(l); };
        0
    };
    { get: get, head: head, delete: delete, post: post, put: put, patch: patch, request: request, header: header, close: close }
};

// ── the one-shot functions ──────────────────────────────────────────────

// request with the options, if any (an optional parameter passes on
// as an option).
def request_opt(method: str, url: str, o: Opts?) -> Response {
    let opts: Opts = {};
    if (o != none) { opts = o!; };
    let none_h: {str => str} = {};
    let pool: [Link] = [];
    let jar: {str => str} = {};
    fetch(method.upper(), url, opts, none_h, pool, false, jar)
};

def request(method: str, url: str, o?: Opts) -> Response { request_opt(method, url, o) };
def get(url: str, o?: Opts) -> Response { request_opt("GET", url, o) };
def head(url: str, o?: Opts) -> Response { request_opt("HEAD", url, o) };
def delete(url: str, o?: Opts) -> Response { request_opt("DELETE", url, o) };

def post(url: str, body: str, o?: Opts) -> Response { request_opt("POST", url, some(with_body(o, body))) };
def put(url: str, body: str, o?: Opts) -> Response { request_opt("PUT", url, some(with_body(o, body))) };
def patch(url: str, body: str, o?: Opts) -> Response { request_opt("PATCH", url, some(with_body(o, body))) };

def with_body(o: Opts?, body: str) -> Opts {
    let opts: Opts = {};
    if (o != none) { opts = o!; };
    {
        headers: opts.headers, body: some(body), timeout: opts.timeout, redirects: opts.redirects,
        insecure: opts.insecure, anchors: opts.anchors
    }
};

export { request, get, head, delete, post, put, patch, session, parse_url, resolve_ref };
