// std/web.y -- the page around a web program.
//
//     import web;
//     if (web.available()) {
//         web.log("platform " + web.platform());
//         let body = web.fetch("/data/hello.txt");
//     }
//
// Off the web every function answers "not available" -- false, "", 0 or none --
// so a program that imports this unit still compiles and runs on linux,
// windows and the kernel: y_os_host_sym answers 0 there and no host call is
// made.
//
// A host call is two private syscalls (arch/web.s, Appendix C):
//
//     y_os_host_sym(name_ptr, len) -> handle > 0, or 0
//     y_os_host_call(handle, args_ptr, n) -> the result; it may block the
//                                            calling green thread
//
// The args are n i64 values. The built-ins are web.platform, web.param,
// web.log, web.eval, web.open_url, web.fetch, web.fetch_len, web.fetch_read
// and web.fetch_free. A function answering a string takes (buf, cap) as its
// last two arguments and returns the length, or -(needed) when the string did
// not fit: call_str retries once with that size (S10). The length 0 is an
// empty string; a small negative is an error, and call_str answers none for
// it (param's "absent" is -ENOENT). web.fetch answers a positive handle,
// web.fetch_len its length, web.fetch_read copies bytes into (buf, cap) and
// web.fetch_free releases it. A page may register its own app.* host
// functions and reach them through sym/call/call_str.
export {
    available, platform, sym, call, call_str, eval, log, param, open_url, fetch
};

// The largest buffer call_str allocates for a retry. A host asking for more is
// reporting an error as a length, not a string that did not fit.
const STR_MAX = 67108864;

// The largest value the string protocol starts with. It only has to be large
// enough for the ordinary answers (a platform name, a query parameter); a
// longer one costs one retry.
const STR_FIRST = 256;

// The largest fetched body this unit allocates. A host that answers a bigger
// length is reporting a resource the wasm heap should not be asked for.
const BODY_MAX = 134217728;

def cstr(s: str) -> [byte] {
    let b = bytes(s);
    b += 0;
    b
};

// A zeroed byte buffer of 'n' bytes; this unit has no other unit to take one
// from (gui, img and tls each carry their own too).
def zeros(n: long) -> [byte] {
    let z: [byte] = [];
    let chunk: [byte] = [];
    let i = 0;
    while (i < 4096) { chunk += 0; i = i + 1; };
    while (z.length + 4096 <= n) { z += chunk; };
    while (z.length < n) { z += 0; };
    z
};

// The caller's argument block as a fresh array, so appending (buf, cap) never
// writes through the caller's array.
def args_of(args: [long]) -> [long] {
    let a: [long] = [];
    foreach (v in args) { a += v; };
    a
};

/** True on the web: there is a host table (web.platform resolves). */
def available() -> bool { sym("web.platform") != 0 };

/** The host's platform: "browser" or "node"; "" off the web. */
def platform() -> str {
    let h = sym("web.platform");
    if (h == 0) { return ""; };
    let r = call_str(h, []);
    if (r == none) { return ""; };
    r!
};

/** The handle of host function 'name': positive, or 0 when there is none. */
def sym(name: str) -> long {
    let b = cstr(name);
    os_call("y_os_host_sym", &b[0], b.length - 1)
};

/** Calls host function 'h' with 'args' and answers the result; 0 when there
is no host function (a 0 handle, or no host at all). */
def call(h: long, args: [long]) -> long {
    if (h <= 0) { return 0; };
    let a = args_of(args);
    if (a.length == 0) { a += 0; };
    os_call("y_os_host_call", h, &a[0], args.length)
};

/** Calls host function 'h' with 'args' followed by (buf, cap) and answers
the string it wrote. none off the web, when the host reports an error, or
when the string still does not fit after one retry.

The two attempts are straight-line, not a loop: S10 allows one retry, and a
loop that allocates a buffer would make the call unprovable from a checked
(no-GC) program. */
def call_str(h: long, args: [long]) -> str? {
    if (h <= 0) { return none; };
    let a = args_of(args);
    let buf: [byte] = zeros(STR_FIRST);
    a += ptr_addr(&buf[0]);
    a += STR_FIRST;
    let r = os_call("y_os_host_call", h, &a[0], a.length);
    if (r >= 0) {
        if (r <= STR_FIRST) { return some(from_bytes(buf[0:r])); };
        return none;
    };
    let need = 0 - r;
    // a small negative is an error (-EIO for a throw, -ENOENT for an absent
    // parameter), not a length
    if (need <= STR_FIRST || need > STR_MAX) { return none; };
    let a2 = args_of(args);
    let buf2: [byte] = zeros(need);
    a2 += ptr_addr(&buf2[0]);
    a2 += need;
    let r2 = os_call("y_os_host_call", h, &a2[0], a2.length);
    if (r2 < 0 || r2 > need) { return none; };
    some(from_bytes(buf2[0:r2]))
};

/** Evaluates JavaScript 'js' in the page and answers its result as a
string; none off the web or when the script throws. */
def eval(js: str) -> str? {
    let h = sym("web.eval");
    if (h == 0) { return none; };
    let b = cstr(js);
    call_str(h, [ptr_addr(&b[0]), b.length - 1])
};

/** Writes 's' to the host console: console.log in the page; the Node host
puts it on the program's stdout with one newline, so the order with puts
holds. Nothing off the web. */
def log(s: str) -> void {
    let h = sym("web.log");
    if (h == 0) { return; };
    let b = cstr(s);
    let a: [long] = [ptr_addr(&b[0]), b.length - 1];
    os_call("y_os_host_call", h, &a[0], 2);
};

/** The URL query parameter 'name', or none when it is absent (browser) or
the host has no query string (Node). */
def param(name: str) -> str? {
    let h = sym("web.param");
    if (h == 0) { return none; };
    let b = cstr(name);
    call_str(h, [ptr_addr(&b[0]), b.length - 1])
};

/** Opens 'url' in a new tab (window.open); false off the web, or when the
browser refused the popup. */
def open_url(url: str) -> bool {
    let h = sym("web.open_url");
    if (h == 0) { return false; };
    let b = cstr(url);
    let a: [long] = [ptr_addr(&b[0]), b.length - 1];
    os_call("y_os_host_call", h, &a[0], 2) > 0
};

// The body of a fetch handle, after its length is known.
def fetch_body(id: long) -> [byte]? {
    let lh = sym("web.fetch_len");
    if (lh == 0) { return none; };
    let la: [long] = [id];
    let n = os_call("y_os_host_call", lh, &la[0], 1);
    if (n < 0 || n > BODY_MAX) { return none; };
    let rh = sym("web.fetch_read");
    if (rh == 0) { return none; };
    let cap = n;
    if (cap == 0) { cap = 1; };
    let buf: [byte] = zeros(cap);
    let ra: [long] = [id, ptr_addr(&buf[0]), cap];
    if (os_call("y_os_host_call", rh, &ra[0], 3) != n) { return none; };
    some(buf[0:n])
};

/** GETs 'url' and answers the body; none on a network error or a status
outside 2xx, and off the web. It blocks the calling green thread until the
host's fetch settles. */
def fetch(url: str) -> [byte]? {
    let h = sym("web.fetch");
    if (h == 0) { return none; };
    let b = cstr(url);
    let a: [long] = [ptr_addr(&b[0]), b.length - 1];
    let id = os_call("y_os_host_call", h, &a[0], 2);
    if (id <= 0) { return none; };
    let out = fetch_body(id);
    let fh = sym("web.fetch_free");
    if (fh != 0) {
        let f: [long] = [id];
        os_call("y_os_host_call", fh, &f[0], 1);
    };
    out
};
