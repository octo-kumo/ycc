// rpc.y -- JSON-RPC 2.0 over stdio: Content-Length framing.
//
// A frame is `Content-Length: N\r\n` [headers] `\r\n` then exactly N bytes of
// UTF-8 JSON. Writing is one write(2) per message, which is what the runtime
// already does for every other output (std/rt.y's y_put_hstr), so a message
// cannot be interleaved with anything else.
//
// Reading is a buffer and a cursor, because one read(2) can return any number of
// bytes: part of a header, several messages, or a fragment of a 64 KB payload.
// fs.read_some is the primitive; nothing above it knows about frames.
//
// This module deliberately does NOT `import fs;`. The program that imports this
// one also imports diag.y, which imports native.y, and native.y already brings
// fs in by name. A second `import fs;` here resolves against a DIFFERENT
// spelling of the same file (see the norm_path note in serve.y), the splicer's
// dedupe misses, and every fs.y definition is reported as a duplicate. A
// compiler bug, recorded in BUGS.md; the workaround is to name fs exactly once,
// and diag.y -> native.y is the one place that does it. A module that wants
// rpc.y on its own has to bring fs in itself.

// ── the reader ──────────────────────────────────────────────────────────

type In = { buf: [byte], pos: long, eof: bool };

def in_new() -> In { { buf: [], pos: 0, eof: false } }

// Pull more bytes. Returns how many arrived; 0 means end of input.
def in_fill(r: In, fd: long) -> long {
    let got = fs.read_some(fd, 65536);
    if (len(got) == 0) {
        r.eof = true;
        return 0;
    }
    r.buf += got;
    len(got)
}

// The next frame's body, or none at end of input. `r.at_line_start` says
// whether anything was consumed from the buffer this call, so a caller can tell
// a clean stop from a stalled one.
def read_frame(r: In, fd: long) -> str? {
    let out: str? = none;
    let want = 0;
    let started = false;

    // Header lines, up to the blank one. A blank line ALWAYS ends them -- the
    // first version only ended on it when no Content-Length had been seen, and
    // so ate the body of every message after the first.
    let go = true;
    while (go) {
        let line = "";
        let done = false;
        let by_lf = false;
        while (!done) {
            if (r.pos < len(r.buf)) {
                let b = r.buf[r.pos];
                r.pos = r.pos + 1;
                if (b == 10) {
                    done = true;               // LF ends the line; CR is dropped
                    by_lf = true;
                } else if (b != 13) {
                    line += chr(b);
                }
            } else if (r.eof) {
                done = true;                   // end of input inside the headers
            } else {
                in_fill(r, fd);
            }
        }
        if (!by_lf) {
            go = false;
        } else if (line == "") {
            go = false;                         // the blank line: headers are done
        } else {
            let v = header_value(line, "content-length");
            if (v != "") {
                // A Content-Length that is not a number is a bad header, not a
                // length: tolong answers none rather than reading what it can.
                let wv = tolong(v);
                if (wv != none) { want = wv!; started = true; };
            }
        }
    }

    if (want > 0) {
        let body: [byte] = [];
        let need = want;
        while (need > 0) {
            if (r.pos < len(r.buf)) {
                let take = len(r.buf) - r.pos;
                if (take > need) { take = need; }
                let i = 0;
                while (i < take) {
                    body += bytes(chr(r.buf[r.pos + i]));
                    i = i + 1;
                }
                r.pos = r.pos + take;
                need = need - take;
            } else if (r.eof) {
                need = 0;                      // truncated: take what came
            } else {
                in_fill(r, fd);
            }
        }
        out = some(from_bytes(body));
    } else if (!started && r.eof) {
        out = none;
    }
    out
}

// The value of `name` from a header line, or "".
def header_value(line: str, name: str) -> str {
    let v = "";
    let n = len(name);
    if (len(line) > n) {
        let k = 0;
        let same = true;
        while (k < n) {
            let a = byte_at(line, k);
            let b = byte_at(name, k);
            let al = a;
            let bl = b;
            if (al >= 65 && al <= 90) { al = al + 32; }
            if (bl >= 65 && bl <= 90) { bl = bl + 32; }
            if (al != bl) { same = false; }
            k = k + 1;
        }
        if (same && byte_at(line, n) == 58) {
            let s = n + 1;
            while (s < len(line) && byte_at(line, s) == 32) { s = s + 1; }
            v = line[s:];
        }
    }
    v
}

// ── the writer ──────────────────────────────────────────────────────────

// One message, one write(2). Content-Length counts BYTES of the body, which is
// not the same as its length in characters.
def write_frame(fd: long, body: str) -> long {
    let n = len(body);
    fs.write_text(fd, "Content-Length: " + tostring(n) + "\r\n\r\n" + body);
    n
}

export { In, in_new, in_fill, read_frame, header_value, write_frame };