// su_fixpoint.y -- self-hosting: ycc compiling its own source reproduces ycc
// byte for byte, and what it builds is itself a working compiler (one that
// miscompiles itself can still be bit-stable, so generation 3 is checked too).
// The compiler's source and std's files compile without a single warning.
//
// Every compile is capped (FP_MEM_KB, 2 GB): the self-compile needs ~0.8 GB and
// once needed ~32 GB while every run still "passed". YSELF names another
// self-hosted build to check instead of ./ycc (`make check`: ./ynew).
import fs;
import yt;
import yc;

def ycc_bin() -> str { yc.abs_path(yt.env("YSELF", yc.YCC)) };

def mem() -> long { yt.num(yt.env("FP_MEM_KB", "2097152"), 2097152) };

def capped(argv: [str], secs: long) -> yt.Res {
    let c = yt.cmd(argv);
    c.merge = true;
    c.timeout = secs * yt.SCALE;
    c.mem_kb = mem();
    yt.run(c)
};

def generations() {
    let d = yt.tmp_dir("fp");
    let src = yc.ROOT + "/src/y/ycc.y";
    let g2 = d + "/gen2";
    let r = capped([ycc_bin(), "-o", g2, src], 600);
    yt.check("ycc compiles its own source", r.code == 0, yt.clip(r.out, 200));
    yt.check("ycc's own source compiles without a warning", yt.size(g2) > 0 && r.out == "", yt.clip(r.out, 300));
    // ./ycc carries its std pack; generation 2 is bare, so its own is attached
    let p = capped([g2, "--std-pack", g2 + ".pack"], 120);
    let packed = d + "/gen2.packed";
    yt.check("generation 2 (and its std pack) is byte-identical to ./ycc",
        yt.size(g2) > 0 && p.code == 0 && yt.concat(packed, [g2, g2 + ".pack"]) && yt.same_file(ycc_bin(), packed),
        "sizes: " + tostring(yt.size(ycc_bin())) + " vs " + tostring(yt.size(packed)));
    // generation 3, without a pack, from the std sources: the same bytes either way
    let g3 = capped([g2, "-o", d + "/gen3", src], 600);
    yt.check("generation 3 reproduces generation 2", g3.code == 0 && yt.same_file(g2, d + "/gen3"),
        "self-built compiler is not stable");
    // a bit-stable compiler still has to work
    yt.write(d + "/probe.y", "def fib(n: long) -> long { if (n < 2) { n } else { self(n - 1) + self(n - 2) } };\n"
        + "let xs: [long] = [];\nlet i = 0;\nwhile (i < 8) { xs += fib(i); i = i + 1; };\n"
        + "print(len(xs));\nprint(xs[7]);\nputs(\"ok\\n\");\n");
    let c = capped([g2, "-o", d + "/probe_bin", d + "/probe.y"], 120);
    if (c.code == 0) {
        let o = yc.run_bin(d + "/probe_bin", [], "", 30);
        yt.check("self-built compiler produces working binaries", o.out == "8\n13\nok\n", "got: " + o.out);
    } else {
        yt.fail("self-built compiler produces working binaries", "compile failed");
    };
    fs.remove_all(d);
};

// std's files, each compiled as a program, and the importable ones imported (a
// std unit linked into a program is never linted, so this is where its
// warnings would show); the kernel's units compile under --kernel.
def std_clean() {
    let d = yt.tmp_dir("fpstd");
    yt.write(d + "/std.y", "import fs;\nimport net;\nimport struct;\nimport crypto;\nimport x509;\nimport tls;\n"
        + "import http;\nimport regex;\nimport json;\nputs(\"ok\\n\");\n");
    let bad = "";
    foreach (f in [d + "/std.y"] + yt.files(yc.ROOT + "/src/y/std", "", ".y")) {
        let b = fs.path_basename(f);
        if (b != "kernel.y" && b != "kmem.y" && b != "yfs.y" && b != "fd.y") {
            let r = capped([ycc_bin(), "-o", d + "/std_bin", f], 120);
            if (r.code != 0 || r.out != "") { bad += " " + b + ": " + yt.clip(r.out, 200); };
        };
    };
    foreach (f in ["t001_hello.y", "u007_fsexec.driver.y"]) {
        let r = capped([ycc_bin(), "--kernel", "-o", d + "/std_bin", yc.ROOT + "/test/kernel/" + f], 120);
        if (r.code != 0 || r.out != "") { bad += " kernel " + f + ": " + yt.clip(r.out, 200); };
    };
    yt.check("std's files compile without a warning (and import fs, net, struct, crypto, x509, tls, http, regex, json)",
        bad == "", bad);
    fs.remove_all(d);
};

def cases() -> [yt.Case] {
    [yt.case_of("fixpoint", "generations", generations), yt.case_of("fixpoint", "std", std_clean)]
};

export { cases };
