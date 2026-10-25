// JSON-RPC framing. The reader owns only the current unread chunk.
import fs;

type In = { buf: [byte], pos: long, eof: bool };

def in_new() -> In { { buf: [], pos: 0, eof: false } }

// Pull more bytes. Returns how many arrived; 0 means end of input.
def in_fill(r: In, fd: long) -> long {
    if (r.pos > 0) { r.buf = r.buf[r.pos:]; r.pos = 0; };
    let got = fs.read_some(fd, 65536);
    if (len(got) == 0) {
        r.eof = true;
        return 0;
    }
    r.buf += got;
    len(got)
}

// The next body, or none at EOF. A truncated body is returned for JSON validation.
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
                if (wv != none) { want = wv !; started = true; };
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
                body += r.buf[r.pos:r.pos + take];
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
    let n = len(name);
    if (len(line) <= n || line[n] != ':' || line[:n].lower() != name.lower()) { return ""; };
    let start = n + 1;
    while (start < len(line) && line[start] == ' ') { start++; };
    line[start:]
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
