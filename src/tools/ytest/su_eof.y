// su_eof.y -- EOF must not be latched: after readline() answers none, a later
// call attempts a fresh read. Proven with a FIFO: the first writer closes
// (EOF), a second opens once the program has printed what it read up to that
// EOF, and writes more. No step depends on timing: phase b polls on a
// wall-clock budget the second writer is well within. Three builds of one
// program: the reference, the C copy, and the built ./ycc ($YSELF).
import fs;
import yt;
import yc;

let PROG = "def drain(tag: str) -> long {
    let n = 0;
    let go = true;
    while (go) {
        let l = readline();
        if (l == none) { go = false; } else { n = n + 1; puts(tag + \":\" + unwrap(l) + \"\\n\"); };
    };
    n
};
// Phase a stops at the first EOF. Phase b keeps polling for a few seconds:
// if EOF were latched every retry would return none and this would print 0.
print(drain(\"a\"));
let t0 = clock_us();
let got = 0;
let go = true;
while (go) {
    let l = readline();
    if (l == none) {
        if (clock_us() - t0 > 8000000) { go = false; };
    } else {
        got = got + 1;
        puts(\"b:\" + unwrap(l) + \"\\n\");
        go = false;
    };
};
print(got);
";

def check(name: str, bin: str) {
    let d = yt.tmp_dir("eof");
    let fifo = d + "/in";
    let out = d + "/out";
    let p = yt.cz(fifo);
    syscall(259, -100, &p[0], 4480, 0);
    // the second write waits for phase a's count: at a fixed delay it once
    // reached a program still starting, and the two writes read as one stream
    let w = fork {
        fs.write_file(fifo, "one\ntwo\n");
        let t0 = clock_us();
        while (!yt.has_line(yt.read(out), "2") && clock_us() - t0 < 30000000) { yt.sleep_us(50000); };
        fs.write_file(fifo, "three\n");
    };
    let c = yt.cmd([bin]);
    c.stdin = fifo;
    c.out = out;
    c.merge = true;
    c.timeout = 30;
    yt.run(c);
    wait_pid(w);
    let got = yt.read(out);
    fs.remove_all(d);
    let want = "a:one\na:two\n2\nb:three\n1\n";
    yt.check(name, got == want, "expected: " + yt.clip(want, 100) + " got: " + yt.clip(got, 200));
};

def build(cc: str, name: str) {
    let f = yt.tmp("eof") + ".y";
    yt.write(f, PROG);
    let b = yt.tmp("bin");
    if (yc.compile(cc, [], f, b, 120).code == 0) {
        check(name, b);
    } else {
        yt.fail(name + " (compile failed)", "");
    };
};

def cases() -> [yt.Case] {
    let s = "stdin-eof";
    let cs = [yt.case_of(s, "reference", () => build(yc.YREF, "reference")),
              yt.case_of(s, "C copy", () => build(yc.CYCC, "C copy"))];
    let self_ = yc.abs_path(yt.env("YSELF", yc.YCC));
    if (fs.is_file(self_)) {
        cs += yt.case_of(s, "built ycc", () => build(self_, "built ycc"));
    } else {
        cs += yt.case_of(s, "built ycc", () => yt.skip("built ycc", "run 'make ycc' first"));
    };
    cs
};

export { cases };
