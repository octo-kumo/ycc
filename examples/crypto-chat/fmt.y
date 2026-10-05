// fmt.y -- line output for the transcript, and an accumulator for it.
//
// `print` puts a newline after every value it is given, so `print("a", 1)`
// writes two lines.  A table column therefore cannot be built by printing its
// cells; every line here is assembled as one string first.
//
// The accumulator exists for the property check: props.P5 has to be able to ask
// "does this text appear anywhere in what the program actually wrote?", and
// that question is only answerable if the program kept what it wrote.

// Every line printed through `line`, in order.
let PRINTED: [str] = [];

def line(s: str) { print(s); PRINTED += s; };

// The whole transcript as one byte string, for a substring search.  Built once,
// at the end, so the search has something real to look at.
def transcript_bytes() -> [byte] { bytes(shown()) };

def shown() -> str { "\n".join(PRINTED) };

def pad(s: str, w: long) -> str { s.pad_right(w, " ") };
def rpad(s: str, w: long) -> str { s.pad_left(w, " ") };

// A numbered section rule: blank line, then a titled line filled to 78 columns.
def rule(n: long, title: str) -> void { head(tostring(n) + ". " + title) };

// An unnumbered section head, same fill.
def head(title: str) -> void {
    let s = "-- " + title + " ";
    let i = len(s);
    while (i < 78) { s += "-"; i = i + 1; };
    line("");
    line(s)
};

// Thousands with spaces: 3670016 -> "3 670 016".  Hand-rolled because the
// language has no number formatting with a grouping character.  Groups are cut
// from the right, so the first group is the only one that may be short.
def thousands(n: long) -> str {
    let s = tostring(n);
    let neg = n < 0;
    let body = "";
    if (neg) { body = s[1:len(s)]; } else { body = s; };
    let cnt = len(body);
    let lead = cnt % 3;
    if (lead == 0) { lead = 3; };
    let out = body[0:lead];
    let i = lead;
    while (i < cnt) {
        out = out + " " + body[i:i + 3];
        i = i + 3;
    };
    if (neg) { "-" + out } else { out }
};

// "  key    value", keys padded to `w` so the values line up.
def kv(k: str, v: str, w: long) -> void { line("  " + k.pad_right(w, " ") + v); };

// A row of a fixed-column table, each cell padded to its own width.
def row(cells: [str], widths: [long]) -> void {
    let s = "";
    let i = 0;
    while (i < len(cells)) {
        let c = cells[i];
        if (i + 1 < len(cells)) { s = s + c.pad_right(widths[i], " "); } else { s = s + c; };
        i = i + 1;
    };
    line(s)
};

export { PRINTED, line, transcript_bytes, shown, pad, rpad, rule, head, thousands, kv, row };