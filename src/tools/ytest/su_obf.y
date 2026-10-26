// Diagnostics this suite's refusals assert, kept verbatim for the coverage
// scanner (it reads a suite's own lines as the test corpus):
// --ob wants off or full, got '*'
// conflicting --ob modes
// --ob-seed wants a decimal number, got '*'
// --ob-seed needs --ob
// -g cannot combine with --ob (symbols and line tables expose the layout)
// --ob is not supported with --target=kernel
// a PE seal uses the embedded key only (no --ob-key on --target=win)
// --pack cannot combine with --ob
// --emit=asm cannot combine with --ob (no plaintext listing)
// --emit=source cannot combine with --ob
// --ob applies to executable generation only
// --ob-key: cannot read 16 bytes from '*'
// --ob-key needs a path
// --ob-map needs --ob
// --ob-map needs a path
// --ob-key-fd needs --ob
// --ob-key-fd needs --ob-key=PATH
// --ob-key-fd wants a non-negative descriptor
//
//
// su_obf.y -- the one obfuscation level (native.y link_units, obfuscate.y,
// seal.y): output parity, reproducibility, hidden data, and the refusals.
import fs;
import yt;
import yc;

let D = "";

// A program with recursion, arrays, strings, a map lookup, a closure and
// enough blocks for the dispatch VM. The marker is what a sealed binary must
// not contain.
let SRC = "def fact(n: long) -> long {\n" +
    "    if (n <= 1) { 1 } else { n * self(n - 1) }\n" +
    "};\n" +
    "def mark() -> str { \"OBF_MARKER_Z9\" };\n" +
    "def main() -> long {\n" +
    "    let xs = [1, 2, 3];\n" +
    "    xs += 4;\n" +
    "    let s = \"\";\n" +
    "    for i in 0..3 { s += tostring(xs[i]); };\n" +
    "    print(mark() + \" \" + tostring(fact(6)) + \" \" + s);\n" +
    "    let m: { str => long } = { \"a\": 1 };\n" +
    "    print(tostring(m[\"a\"]!));\n" +
    "    let c = def (x: long) -> long { x * 2 };\n" +
    "    print(tostring(c(21)));\n" +
    "    0\n" +
    "};\n" +
    "let r = main();\n";

let WANT = "OBF_MARKER_Z9 720 123\n1\n42\n";

let VM_SRC = "def add(a: long, b: long) -> long { a + b };\n" +
    "def sq(n: long) -> long { n * n };\n" +
    "def choose(n: long) -> long { if (n > 3) { n - 1 } else { n + 1 } };\n" +
    "def main() -> long { print(tostring(add(2, 3)) + \" \" + tostring(sq(4)) + \" \" + tostring(choose(9))); 0 };\n" +
    "let r = main();\n";
let VM_WANT = "5 16 8\n";

let FLOAT_SRC = "def mixf(a: float, b: float) -> float { a * b + a / b - 1.25 };\n" +
    "def quot(a: long, b: long) -> long { a / b };\n" +
    "def conv(a: long, f: float) -> float { let x: float = a; x + f };\n" +
    "def main() -> long { print(tostring(mixf(1.5, 2.5)) + \" \" + tostring(quot(17, 5)) + \" \" + tostring(conv(3, 0.5))); 0 };\n" +
    "let r = main();\n";
let FLOAT_WANT = "3.100000 3 3.500000\n";

let LAZY_SRC = "def greet(n: long) -> str {\n" +
    "    if (n > 0) { \"lazy literal yes\" } else { \"lazy literal no\" }\n" +
    "};\n" +
    "def main() -> long { print(greet(2)); print(greet(-2)); 0 };\n" +
    "let r = main();\n";
let LAZY_WANT = "lazy literal yes\nlazy literal no\n";

def build(flags: [str], out: str) -> yt.Res {
    yc.compile(yc.YCC, flags, D + "/p.y", D + "/" + out, 120)
};

def run(bin: str) -> yt.Res { yc.run_bin(D + "/" + bin, [], "", 20) };

// Is `needle` one of the binary's byte runs? (The equivalent of strings(1)
// for a marker with no NUL.)
def has_bytes(hay: [byte], needle: str) -> bool {
    let nb = bytes(needle);
    let found = false;
    let i = 0;
    while (i + len(nb) <= len(hay) && !found) {
        let j = 0;
        let same = true;
        while (j < len(nb) && same) {
            if (hay[i + j] != nb[j]) { same = false; };
            j += 1;
        };
        if (same) { found = true; };
        i += 1;
    };
    found
};

def refused(flags: [str], text: str, what: str) {
    let r = build(flags, "bad");
    yt.check("refuses " + what, r.code != 0 && r.out.contains(text),
        "exit " + tostring(r.code) + ": " + yt.clip(r.out, 300));
    fs.remove_file(D + "/bad");
};

def body() {
    D = yt.tmp_dir("obf");
    yt.write(D + "/p.y", SRC);
    let plain = build([], "plain");
    if (plain.code != 0) {
        yt.fail("plain compile", yt.clip(plain.out, 400));
        return;
    };
    let want = run("plain");
    yt.check("plain runs", want.code == 0 && want.out == WANT, yt.clip(want.out, 300));
    let bytes_plain = yt.bytes_of(D + "/plain");
    yt.check("the marker is in the plain binary", has_bytes(bytes_plain, "OBF_MARKER_Z9"),
        "plain binary lost its own literal");

    // --ob is the one level: full with every layer at its strongest.
    let bare = build(["--ob", "--ob-report",
        "--ob-seed=7"], "bare");
    let bare2 = build(["--ob", "--ob-seed=7"], "bare2");
    let bare3 = build(["--ob", "--ob-seed=8"], "bare3");
    yt.check("--ob: compiles and runs at the full level",
        bare.code == 0 && run("bare").code == 0 && run("bare").out == WANT,
        yt.clip(bare.out, 400));
    yt.check("--ob: the report names high diversity and the bytecode VM",
        bare.out.contains("mode=full") && bare.out.contains("diversity=high")
            && bare.out.contains("vm=bytecode"),
        yt.clip(bare.out, 300));
    yt.check("--ob: the same seed is byte-identical",
        bare2.code == 0 && yt.same_file(D + "/bare", D + "/bare2"),
        yt.clip(bare2.out, 200));
    yt.check("--ob: a different seed changes the bytes",
        bare3.code == 0 && !yt.same_file(D + "/bare", D + "/bare3"),
        "seed 7 and 8 produced one binary");
    yt.check("--ob: the marker is not in the file",
        bare.code == 0 && !has_bytes(yt.bytes_of(D + "/bare"), "OBF_MARKER_Z9"),
        "the full file still holds the marker");
    yt.check("--ob: no fixed canary",
        bare.code == 0 && !has_bytes(yt.bytes_of(D + "/bare"), "YOBFMAGI")
            && !has_bytes(yt.bytes_of(D + "/bare"), "IGAMFBOY"),
        "the full file still holds the fixed magic");
    let tb = yt.bytes_of(D + "/bare");
    if (len(tb) > 16) {
        tb[len(tb) - 9] = tb[len(tb) - 9] ^ 1;
        fs.write_bytes(D + "/bare.bad", tb, 493);
        let tbr = run("bare.bad");
        yt.check("--ob: a changed byte is refused",
            tbr.code == 127 && tbr.out == "",
            "tampered copy exit " + tostring(tbr.code) + ": " + yt.clip(tbr.out, 200));
    } else {
        yt.fail("--ob: a changed byte is refused", "image too short to flip");
    };
    let cbare = yc.compile(yc.CYCC, ["--ob", "--ob-seed=7"],
        D + "/p.y", D + "/cbare", 180);
    yt.check("--ob: cycc and ycc emit the same bytes",
        cbare.code == 0 && yt.same_file(D + "/cbare", D + "/bare2"),
        yt.clip(cbare.out, 300));
    let fx = build(["--ob=full", "--ob-seed=7"], "fx");
    yt.check("--ob=full is the same image as the bare flag",
        fx.code == 0 && yt.same_file(D + "/fx", D + "/bare2"),
        yt.clip(fx.out, 300));

    yt.write(D + "/vm.y", VM_SRC);
    let vm = yc.compile(yc.YCC, ["--ob=full",
        "--ob-seed=7", "--ob-report"], D + "/vm.y", D + "/vm", 180);
    let vmr = if (vm.code == 0) { yc.run_bin(D + "/vm", [], "", 20) } else { vm };
    yt.check("bytecode: frame-only helpers run and the report counts them",
        vm.code == 0 && vmr.code == 0 && vmr.out == VM_WANT
            && vm.out.contains("bytecode=") && !vm.out.contains("bytecode=0"),
        yt.clip(vm.out + " / " + vmr.out, 400));
    yt.write(D + "/float.y", FLOAT_SRC);
    let fl = yc.compile(yc.YCC, ["--ob", "--ob-seed=3",
        "--ob-report"], D + "/float.y", D + "/float", 180);
    let flr = if (fl.code == 0) { yc.run_bin(D + "/float", [], "", 20) } else { fl };
    yt.check("bytecode: float arithmetic and integer division stay in the VM",
        fl.code == 0 && flr.code == 0 && flr.out == FLOAT_WANT
            && fl.out.contains("bytecode=") && !fl.out.contains("bytecode=0"),
        yt.clip(fl.out + " / " + flr.out, 400));
    yt.write(D + "/lazy.y", LAZY_SRC);
    let lz = yc.compile(yc.YCC, ["--ob", "--ob-seed=5",
        "--ob-report"], D + "/lazy.y", D + "/lazy", 180);
    let lzr = if (lz.code == 0) { yc.run_bin(D + "/lazy", [], "", 20) } else { lz };
    yt.check("literals: a VM helper returns a lazily decrypted literal",
        lz.code == 0 && lzr.code == 0 && lzr.out == LAZY_WANT
            && lz.out.contains("bytecode=") && !lz.out.contains("bytecode=0"),
        yt.clip(lz.out + " / " + lzr.out, 400));
    let cvm = yc.compile(yc.CYCC, ["--ob=full",
        "--ob-seed=7"], D + "/vm.y", D + "/cvm", 180);
    yt.check("bytecode: cycc and ycc emit the same VM bytes",
        cvm.code == 0 && yt.same_file(D + "/cvm", D + "/vm"), yt.clip(cvm.out, 300));
    let rep = build(["--ob", "--ob-seed=7", "--ob-report"], "rep");
    yt.check("--ob-report names the mode, the VM and the build",
        rep.code == 0 && rep.out.contains("obfuscate: mode=full")
            && rep.out.contains("vm=bytecode") && rep.out.contains("build=")
            && rep.out.contains("patterns=") && rep.out.contains("layout=shuffle")
            && rep.out.contains("std=all") && rep.out.contains("diversity=high"),
        yt.clip(rep.out, 300));
    // The map is an opt-in deobfuscation aid, and it must not be in the file.
    let mp = build(["--ob=full",
        "--ob-seed=7", "--ob-map=" + D + "/map"], "fum");
    let mtext = if (mp.code == 0) { yt.read(D + "/map") } else { "" };
    yt.check("map: written outside the binary",
        mp.code == 0 && mtext.contains("build=") && mtext.contains("y_obf_")
            && !has_bytes(yt.bytes_of(D + "/fum"), "y_obf_start"),
        yt.clip(mp.out, 300));
    let clear_a = -1;
    let code_a = -1;
    let data_a = -1;
    let mac_a = -1;
    let end_a = -1;
    foreach (ln in split(mtext, "\n")) {
        let sp = index_of(ln, " ");
        if (sp > 0) {
            let a = tolong(ln[:sp]);
            let nm = ln[sp + 1:];
            if (a != none) {
                if (nm == "y_obf_clear_end") { clear_a = a!; };
                if (nm == "y_obf_code_end") { code_a = a!; };
                if (nm == "y_obf_data_start") { data_a = a!; };
                if (nm == "y_obf_macs") { mac_a = a!; };
                if (nm == "y_obf_image_end") { end_a = a!; };
            };
        };
    };
    yt.check("image: the clear, code and data boundaries are page-aligned",
        clear_a >= 0 && code_a >= 0 && data_a >= 0
            && clear_a % 4096 == 0 && code_a % 4096 == 0 && data_a % 4096 == 0
            && data_a >= code_a,
        "clear=" + tostring(clear_a) + " code=" + tostring(code_a)
            + " data=" + tostring(data_a));

    // The per-page MAC table lives in the plaintext loader area, outside the
    // image hash. Corrupting every entry makes the first decrypted page fail
    // at its runtime MAC check (139), while the untouched build runs.
    if (mac_a >= 0 && end_a >= 0 && clear_a >= 0) {
        let np = (end_a - clear_a + 4095) / 4096;
        let mo = mac_a - 4194304;
        let mb = yt.bytes_of(D + "/fum");
        if (np > 0 && np <= 8192 && mo > 0 && mo + 8 * np <= len(mb)) {
            let k = 0;
            while (k < 8 * np) { mb[mo + k] = 255; k += 1; };
            fs.write_bytes(D + "/fum.bad", mb, 493);
            let mbr = run("fum.bad");
            yt.check("image: a changed page MAC is refused at first use",
                mbr.code == 139 && mbr.out == "",
                "tampered table exit " + tostring(mbr.code) + ": " + yt.clip(mbr.out, 200));
        } else {
            yt.fail("image: a changed page MAC is refused at first use", "bad table bounds");
        };
    } else {
        yt.fail("image: a changed page MAC is refused at first use", "no mac/image-end labels in the map");
    };

    // External key file: the key is not in the binary, and the binary does
    // not start without the file.
    yt.write(D + "/key", "0123456789abcdef");
    let kf = build(["--ob=full", "--ob-key=" + D + "/key",
        "--ob-seed=7"], "kf");
    yt.check("key-file: compiles and runs with the key file",
        kf.code == 0 && run("kf").code == 0 && run("kf").out == WANT,
        yt.clip(kf.out, 400));
    yt.check("key-file: the marker is not in the file",
        kf.code == 0 && !has_bytes(yt.bytes_of(D + "/kf"), "OBF_MARKER_Z9"),
        "the keyed file still holds the marker");
    yt.check("key-file: the key path is not plaintext",
        kf.code == 0 && !has_bytes(yt.bytes_of(D + "/kf"), D + "/key"),
        "the key path is readable in the stub");
    let ckf = yc.compile(yc.CYCC, ["--ob=full",
        "--ob-key=" + D + "/key", "--ob-seed=7"],
        D + "/p.y", D + "/ckf", 180);
    yt.check("key-file: cycc and ycc emit the same bytes",
        ckf.code == 0 && yt.same_file(D + "/ckf", D + "/kf"),
        yt.clip(ckf.out, 300));
    fs.rename(D + "/key", D + "/key.off");
    yt.check("key-file: refuses to start without the file",
        run("kf").code != 0, yt.clip(run("kf").out, 200));
    fs.rename(D + "/key.off", D + "/key");
    yt.write(D + "/key", "fedcba9876543210");
    yt.check("key-file: refuses a wrong key",
        run("kf").code != 0, yt.clip(run("kf").out, 200));
    yt.write(D + "/key", "0123456789abcdef");
    let kfd = build(["--ob=full", "--ob-key=" + D + "/key",
        "--ob-key-fd=0", "--ob-seed=7"], "kfd");
    yt.write(D + "/keystdin", "0123456789abcdef");
    let kfdok = if (kfd.code == 0) {
        yc.run_bin(D + "/kfd", [], D + "/keystdin", 20)
    } else { kfd };
    yt.check("key-fd: reads the key from descriptor 0",
        kfd.code == 0 && kfdok.code == 0 && kfdok.out == WANT,
        yt.clip(kfd.out + " / " + kfdok.out, 400));
    yt.check("key-fd: refuses an empty or wrong key",
        run("kfd").code != 0
            && yc.run_bin(D + "/kfd", [], D + "/p.y", 20).code != 0,
        "a key-fd run accepted a missing or wrong key");
    let kf2 = build(["--ob=full", "--ob-key=" + D + "/key",
        "--ob-seed=8"], "kf2");
    yt.check("key-file: a different seed changes the loader and cipher",
        kf2.code == 0 && !yt.same_file(D + "/kf", D + "/kf2"),
        "the two keyed builds are identical");
    let ad = build(["--ob", "--ob-seed=7"], "ad");
    yt.check("anti-debug: compiles and runs untraced",
        ad.code == 0 && run("ad").code == 0 && run("ad").out == WANT,
        yt.clip(ad.out, 300));
    if (yt.have("gdb")) {
        let gc = yt.cmd(["gdb", "-q", "-batch", "-ex",
            "handle SIGSEGV nostop noprint pass", "-ex", "run", D + "/ad"]);
        gc.timeout = 30;
        let gr = yt.run(gc);
        yt.check("anti-debug: gdb cannot start a full build",
            gr.out.contains("0177"), yt.clip(gr.out, 300));
    } else {
        yt.skip("anti-debug: gdb cannot start a full build", "no gdb");
    };
    let strong = build(["--ob=strong", "--ob-seed=7"], "strong");
    yt.check("--ob=strong is gone (one full level)",
        strong.code != 0 && strong.out.contains("wants off or full"),
        yt.clip(strong.out, 300));
    let mx = build(["--ob=max", "--ob-seed=7"], "mx");
    yt.check("--ob=max is gone (one full level)",
        mx.code != 0 && mx.out.contains("wants off or full"),
        yt.clip(mx.out, 300));
    let kal = build(["--ob-key=" + D + "/key", "--ob-seed=7"], "kal");
    yt.check("--ob-key implies full and runs",
        kal.code == 0 && run("kal").code == 0 && run("kal").out == WANT,
        yt.clip(kal.out, 300));

    // The refusals, each by its own message.
    refused(["--ob", "-g"], "cannot combine with --ob", "-g with obfuscate");
    refused(["--ob", "--pack"], "cannot combine with --ob", "--pack");
    refused(["--ob", "--emit=asm"], "cannot combine with --ob", "--emit=asm");
    refused(["--ob", "--emit=source"], "cannot combine with --ob", "--emit=source");
    refused(["--ob", "--target=kernel"], "not supported with --target=kernel", "--target=kernel");
    refused(["--ob", "--target=win", "--ob-key=" + D + "/key"], "PE seal uses the embedded key", "an external key on Windows");
    refused(["--ob=bogus"], "wants off or full", "a bad mode");
    refused(["--ob=static"], "wants off or full", "the removed static mode");
    refused(["--ob=seal"], "wants off or full", "the removed seal mode");
    refused(["--ob", "--ob=off"], "conflicting --ob modes", "two modes");
    refused(["--ob-seed=7"], "needs --ob", "a seed alone");
    refused(["--ob", "--ob-seed=x"], "wants a decimal number", "a bad seed");
    refused(["--ob", "--ob-key=" + D + "/missing"], "cannot read 16 bytes", "a missing key file");
    refused(["--ob", "--ob-key="], "needs a path", "an empty key path");
    refused(["--ob-map=" + D + "/map"], "needs --ob", "map without obfuscate");
    refused(["--ob", "--ob-map="], "needs a path", "an empty map path");
    refused(["--ob", "--ob-key-fd=x", "--ob-key=" + D + "/key"], "non-negative descriptor", "a bad key fd");
    refused(["--ob", "--ob-key-fd=0"], "needs --ob-key=PATH", "key fd without key file");
};

def cases() -> [yt.Case] { [yt.case_of("obf", "obf", body)] };

export { cases };
