// su_port.y -- the port gate: the C copy (cycc, PORTING.md) must write
// BYTE-IDENTICAL binaries to the reference for every test program and for the
// compiler's own source, print the same warnings doing so, and reject what the
// reference rejects with the same diagnostics. Only exit 1 is a rejection: a
// timeout or a crash is never "rejected by both".
//
// port: Linux, at warning levels 0, 1 and 2 (each level-N lint check draws
//   nothing below N, so only a pass at that level can see a C/Y divergence in
//   it; a warning level changes what is said, never what is emitted).
//   YPORT_SELF=0 leaves src/y/ycc.y out, for a caller that just compared it.
// pe-port: --target=windows, with and without -g, which the Linux pass cannot
//   see (a -g line marker once trapped every cycc PE build for ten rounds).
//   A program importing net or tui (http, tls) may differ: those are the only
//   std units with raw `syscall` sites, expanded with the HOST's convention
//   when packed. That byte difference is a SKIP; exits and diagnostics gate.
import yt;
import yc;

def corpus(self_too: bool) -> [str] {
    let fs_ = yt.tree(yc.ROOT + "/test/y", ".y");
    if (self_too && yt.env("YPORT_SELF", "1") != "0") { fs_ += yc.ROOT + "/src/y/ycc.y"; };
    fs_
};

def port() -> [yt.Case] {
    let cs: [yt.Case] = [];
    let files = corpus(true);
    foreach (w in [[], ["-W", "1"], ["-W", "2"]]) {
        let tag = join(w, " ");
        foreach (f in files) {
            cs += yt.case_of("port", f, () => yc.port_check(f, w, tag, false));
        };
    };
    cs
};

// `import net;`-style lines naming a module with raw syscalls
def pe_gap(file: str) -> bool {
    foreach (l in yt.read(file).split("\n")) {
        let t = l.trim();
        if (t.starts_with("import") && t.length > 7 && (t[6] == 32 || t[6] == 9)) {
            let rest = t[7:].trim();
            foreach (m in ["net", "tui", "http", "tls"]) {
                if (rest.starts_with(m) && rest[m.length:].trim() == ";") { return true; };
            };
        };
    };
    false
};

def pe_port() -> [yt.Case] {
    let cs: [yt.Case] = [];
    let files = corpus(false);
    foreach (g in [false, true]) {
        foreach (f in files) {
            let flags = if (g) { ["--target=windows", "-g"] } else { ["--target=windows"] };
            let tag = if (g) { "-g" } else { "" };
            cs += yt.case_of("pe-port", f, () => yc.port_check(f, flags, tag, pe_gap(f)));
        };
    };
    cs
};

export { port, pe_port, corpus };
