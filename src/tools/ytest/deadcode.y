// deadcode.y -- static reachability of a `ycc -S` listing: which emitted
// instructions can never execute.
//
// The tree shaker works on labels, so it can drop a whole function -- but not
// see that the instructions after an unconditional `jmp` or a `ret` are dead,
// nor that a block nothing branches to (and nothing falls into) is
// unreachable. This reads the shaken listing and counts both, so a runtime
// addition that leaves rubble behind is caught by a test instead of by reading
// the disassembly. An indirect `jmp`/`call` is a jump to every label, which can
// only make the answer more conservative.
//
//   ytest deadcode [-v] [--max N] FILE.s    exit 1 past N (default 0)
import fs;
import yt;

def is_start(c: long) -> bool {
    (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 46 || c == 36
};

def is_cont(c: long) -> bool { is_start(c) || (c >= 48 && c <= 57) };

def is_lower(c: long) -> bool { c >= 97 && c <= 122 };

def is_space(c: long) -> bool { c == 32 || c == 9 };

// The label a line starts (`name:`), or "".
def label_of(l: str) -> str {
    if (l.length == 0 || !is_start(l[0])) { return ""; };
    let i = 1;
    while (i < l.length && is_cont(l[i])) { i += 1; };
    if (i < l.length && l[i] == 58) { l[0:i] } else { "" }
};

// The identifier-shaped words of s.
def idents(s: str) -> [str] {
    let r: [str] = [];
    let i = 0;
    while (i < s.length) {
        if (is_start(s[i])) {
            let j = i + 1;
            while (j < s.length && is_cont(s[j])) { j += 1; };
            r += s[i:j];
            i = j;
        } else {
            i += 1;
        };
    };
    r
};

/** The dead instructions' count and, with `verbose`, the report lines. */
type Dead = { n: long, blocks: long, lines: [str] };

def scan(text: str, verbose: bool) -> Dead {
    let labs: [str] = [];
    let mns: [[str]] = [];
    let ops: [[str]] = [];
    let txts: [[str]] = [];
    let cur = "";
    let have = false;
    let m: [str] = [];
    let o: [str] = [];
    let t: [str] = [];
    let labels: {str => long} = {};
    let src = text.split("\n");
    foreach (raw in src) {
        let lab = label_of(raw);
        if (lab != "") {
            if (have || m.length > 0) {
                labs += cur;
                mns += [m];
                ops += [o];
                txts += [t];
            };
            cur = lab;
            have = true;
            labels[lab] = 1;
            m = [];
            o = [];
            t = [];
        } else if (raw.trim() != "" && !raw.trim().starts_with("#") && is_space(raw[0])) {
            let i = 0;
            while (i < raw.length && is_space(raw[i])) { i += 1; };
            if (i < raw.length && is_lower(raw[i])) {
                let j = i + 1;
                while (j < raw.length && (is_lower(raw[j]) || (raw[j] >= 48 && raw[j] <= 57))) { j += 1; };
                m += raw[i:j];
                o += raw[j:].trim();
                t += raw.trim();
            };
        };
    };
    if (have || m.length > 0) {
        labs += cur;
        mns += [m];
        ops += [o];
        txts += [t];
    };
    let nb = labs.length;
    let index: {str => long} = {};
    for b in 0..nb {
        if (labs[b] != "" && !(labs[b] in index)) { index[labs[b]] = b; };
    };
    let all: [long] = values(index);
    // roots: _start, every .globl, and a label named from data (`.quad f`)
    let roots: [str] = ["_start"];
    foreach (raw in src) {
        let st = raw.trim();
        if (raw.starts_with(".globl") && raw.length > 6 && is_space(raw[6])) {
            let w = idents(raw[7:]);
            if (w.length > 0) { roots += w[0]; };
        } else if (st.starts_with(".") && !st.starts_with(".globl")) {
            foreach (w in idents(st)) {
                if (w in labels) { roots += w; };
            };
        };
    };
    let edges: [[long]] = [];
    let falls: [bool] = [];
    let tails: [[str]] = [];
    for b in 0..nb {
        let out: [long] = [];
        let dead: [str] = [];
        let stopped = false;
        for k in 0..mns[b].length {
            let mn = mns[b][k];
            let rest = ops[b][k];
            if (stopped) {
                dead += txts[b][k];
            } else if (mn == "call") {
                if (rest.starts_with("*")) { out += all; }
                else if (rest in index) { out += index[rest]!; };
            } else if (mn.starts_with("j")) {
                if (rest.starts_with("*")) {
                    out += all;
                } else {
                    let tgt = rest.split(",")[0].trim();
                    if (tgt in index) { out += index[tgt]!; };
                };
                if (mn == "jmp") { stopped = true; };
            } else if (mn == "ret" || mn == "retq" || mn == "hlt" || mn == "ud2") {
                stopped = true;
            };
        };
        // an EMPTY block falls through too: two labels side by side
        edges += [out];
        falls += !stopped;
        tails += [dead];
    };
    let reach: [bool] = [];
    for b in 0..nb { reach += false; };
    let work: [long] = [];
    foreach (r in roots) {
        if (r in index) { work += index[r]!; };
    };
    // a block is pushed only when first reached, so the stack stays O(blocks)
    let top = 0;
    foreach (w in work) {
        if (!reach[w]) {
            reach[w] = true;
            work[top] = w;
            top += 1;
        };
    };
    while (top > 0) {
        top -= 1;
        let b = work[top];
        let next = edges[b];
        if (falls[b] && b + 1 < nb) { next = next + [b + 1]; };
        foreach (x in next) {
            if (!reach[x]) {
                reach[x] = true;
                if (top < work.length) { work[top] = x; } else { work += x; };
                top += 1;
            };
        };
    };
    let n = 0;
    let nblk = 0;
    let lines: [str] = [];
    for b in 0..nb {
        if (!reach[b]) {
            nblk += 1;
            n += txts[b].length;
            if (verbose && txts[b].length > 0) {
                lines += "unreachable block " + labs[b] + ":";
                foreach (x in txts[b]) { lines += "    " + x; };
            };
        } else {
            n += tails[b].length;
        };
    };
    if (verbose) {
        for b in 0..nb {
            foreach (x in tails[b]) { lines += "dead tail in " + labs[b] + ": " + x; };
        };
    };
    { n: n, blocks: nblk, lines: lines }
};

def summary(d: Dead) -> str {
    "deadcode: " + tostring(d.n) + " unreachable instruction(s) in " + tostring(d.blocks) + " block(s)"
};

/** `ytest deadcode [-v] [--max N] FILE`. */
def main(av: [str]) -> long {
    let verbose = false;
    let limit = 0;
    let file = "";
    let i = 0;
    while (i < av.length) {
        if (av[i] == "-v") { verbose = true; }
        else if (av[i] == "--max" && i + 1 < av.length) { limit = yt.num(av[i + 1], 0); i += 1; }
        else { file = av[i]; };
        i += 1;
    };
    let text = fs.read_file(file);
    if (text == none) {
        eputs("deadcode: cannot read " + file);
        return 2;
    };
    let d = scan(text!, verbose);
    foreach (l in d.lines) { print(l); };
    print(summary(d));
    if (d.n <= limit) { 0 } else { 1 }
};

export { Dead, scan, summary, main, is_cont };
