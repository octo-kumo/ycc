// su_kernel.y -- `ycc --target=kernel`: the ELF32 Multiboot image, its serial console
// and its `irq N def` handlers, booted under qemu-system-x86_64.
//
// The two engines are the built compiler and the C copy: every image and every
// --emit=asm listing must be the same from both, and fit the one 2 MB page of kernel
// mapping (a 256 KB budget). Every `t*`/`x*` case is then booted: its serial
// output must start with the case's .expected (a kernel that halts never
// exits, so qemu is killed after QTIME seconds), and a `.exit` is qemu's own
// status through the isa-debug-exit port. `u*` cases run a ycc-compiled Linux
// program in ring 3 under a --target=kernel driver. `e*` are rejections compiled with
// --target=kernel, `h*` without, each needing every `// expect-error:` it carries.
// Without qemu the images, listings and rejections are still checked; only the
// boots are skipped.
import fs;
import yt;
import yc;

let K = "";

def qemu() -> str { yt.env("QEMU", "qemu-system-x86_64") };

def kc(cc: str, args: [str], out: str) -> yt.Res {
    let c = yt.cmd([cc] + args);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 60 * yt.SCALE;
    if (out != "") { c.out = out; };
    yt.run(c)
};

// Boot an image: qemu's status and the first bytes of the serial output,
// against `want`.
def boot(base: str, img: str, initrd: str, stdin: str, what: str) {
    if (!yt.have(qemu())) {
        yt.skip(base + ": " + what, "no " + qemu());
        return;
    };
    let exp = yt.read(K + "/" + base + ".expected");
    let q = qemu() + " -kernel " + yt.q(img) + (if (initrd != "") { " -initrd " + yt.q(initrd) } else { "" })
        + " -serial stdio -display none -no-reboot -device isa-debug-exit -monitor none 2>/dev/null";
    // the input is fed a second in: the guest's serial_init clears the UART's
    // receive FIFO, so a byte that arrived before it ran would be discarded
    let line = if (stdin != "") { "{ sleep 1; cat " + yt.q(stdin) + "; } | " + q } else { q + " </dev/null" };
    let c = yt.cmd(["/bin/sh", "-c", line]);
    c.timeout = yt.num(yt.env("QTIME", "6"), 6);
    let r = yt.run(c);
    let head = if (r.out.length > exp.length) { r.out[0:exp.length] } else { r.out };
    if (head != exp) {
        yt.fail(base + ": serial output differs", "expected: " + yt.clip(exp, 300) + " got: " + yt.clip(head, 300));
        return;
    };
    yt.pass(base + ": " + what);
    if (fs.is_file(K + "/" + base + ".exit")) {
        let want = yt.num(yt.read(K + "/" + base + ".exit").trim(), -1);
        yt.check(base + ": kexit -> qemu status " + tostring(r.code), r.code == want,
            "qemu status " + tostring(r.code) + ", wanted " + tostring(want));
    };
};

def booted(src: str, base: str) {
    if (!fs.is_file(K + "/" + base + ".expected")) {
        yt.fail(base + ": no .expected", "");
        return;
    };
    let w = yt.tmp_dir("k");
    let yimg = w + "/y.elf";
    let r = kc(yc.YCC, ["--target=kernel", src, "-o", yimg], "");
    if (r.code != 0) {
        yt.fail(base + ": " + yc.YCC + " --target=kernel failed", yt.clip(r.out, 400));
        return;
    };
    let c = kc(yc.CYCC, ["--target=kernel", src, "-o", w + "/c.elf"], "");
    if (c.code != 0) {
        yt.fail(base + ": " + yc.CYCC + " --target=kernel failed", yt.clip(c.out, 400));
        return;
    };
    if (!yt.same_file(yimg, w + "/c.elf")) {
        yt.fail(base + ": " + yc.CYCC + " and " + yc.YCC + " images differ", "");
        return;
    };
    // --emit=asm is the same program in text: this catches a ported encoder arm
    if (kc(yc.YCC, ["--target=kernel", "--emit=asm", src], "").out != kc(yc.CYCC, ["--target=kernel", "--emit=asm", src], "").out) {
        yt.fail(base + ": --emit=asm listings differ", "");
        return;
    };
    // the "kernel must be small" ratchet: one 2 MB page of kernel mapping
    if (yt.size(yimg) > 262144) {
        yt.fail(base + ": image is " + tostring(yt.size(yimg)) + " bytes (budget 262144)", "");
        return;
    };
    let stdin = K + "/" + base + ".stdin";
    boot(base, yimg, "", if (fs.is_file(stdin)) { stdin } else { "" }, "boots, serial output matches");
    fs.remove_all(w);
};

// One driver (uland.y, compiled with --target=kernel) and one program per case,
// compiled by the ORDINARY target: the kernel implements the ABI the program
// already speaks.
def userland(usrc: str, base: str) {
    let w = yt.tmp_dir("u");
    let drv = if (fs.is_file(K + "/" + base + ".driver.y")) { K + "/" + base + ".driver.y" } else { K + "/uland.y" };
    let r = kc(yc.YCC, ["--target=kernel", drv, "-o", w + "/k.elf"], "");
    if (r.code != 0) {
        yt.fail(base + ": the driver failed to compile", yt.clip(r.out, 400));
        return;
    };
    let p = kc(yc.YCC, [usrc, "-o", w + "/p"], "");
    if (p.code != 0) {
        yt.fail(base + ": the program failed to compile (ordinary target)", yt.clip(p.out, 400));
        return;
    };
    kc(yc.CYCC, ["--target=kernel", drv, "-o", w + "/kc.elf"], "");
    kc(yc.CYCC, [usrc, "-o", w + "/pc"], "");
    if (!yt.same_file(w + "/k.elf", w + "/kc.elf")) {
        yt.fail(base + ": the driver's images differ between the compilers", "");
        return;
    };
    if (!yt.same_file(w + "/p", w + "/pc")) {
        yt.fail(base + ": the programs differ between the compilers", "");
        return;
    };
    if (!fs.is_file(K + "/" + base + ".expected")) {
        yt.fail(base + ": no .expected", "");
        return;
    };
    if (yt.size(w + "/k.elf") > 262144) {
        yt.fail(base + ": the driver's image is over budget", "");
        return;
    };
    boot(base, w + "/k.elf", w + "/p", "", "the program runs in ring 3");
    fs.remove_all(w);
};

def reject(src: str, base: str, kernel: bool) {
    let b = yt.tmp("bin");
    let r = kc(yc.YCC, (if (kernel) { ["--target=kernel"] } else { [] }) + [src, "-o", b], "");
    if (r.code == 0) {
        yt.fail(base + ": " + (if (kernel) { "--target=kernel" } else { "the hosted compiler" }) + " accepted it", "");
        return;
    };
    let bad = false;
    foreach (l in yt.read(src).split("\n")) {
        let i = l.index_of("// expect-error: ");
        if (i >= 0 && !r.out.contains(l[i + 17:])) {
            yt.fail(base + ": missing diagnostic '" + l[i + 17:] + "'", "");
            bad = true;
        };
    };
    if (!bad) { yt.pass(base + ": rejected with its diagnostics"); };
};

// The driver's own refusals: flag combinations, not programs.
def driver(what: str, want: str, args: [str]) {
    let r = kc(yc.YCC, args, "");
    yt.check("driver: " + what, r.out.contains(want), "wanted '" + want + "', got: " + yt.clip(r.out, 300));
};

def cases() -> [yt.Case] {
    K = yc.ROOT + "/test/kernel";
    let s = "kernel";
    let cs: [yt.Case] = [];
    foreach (f in yt.files(K, "t", ".y") + yt.files(K, "x", ".y")) {
        let base = fs.path_stem(f);
        cs += yt.case_of(s, base, () => booted(f, base));
    };
    foreach (f in yt.files(K, "u", ".user.y")) {
        let base = fs.path_basename(f).replace(".user.y", "");
        cs += yt.case_of(s, base, () => userland(f, base));
    };
    let t1 = K + "/t001_hello.y";
    let o = yt.scratch() + "/x.elf";
    cs += yt.case_of(s, "driver", () => {
        driver("--target=kernel with -g", "-g is not supported with --target=kernel", ["--target=kernel", "-g", t1, "-o", o]);
        driver("--target=kernel run", "--target=kernel cannot run its image (boot it with 'qemu-system-x86_64 -kernel')", ["--target=kernel", "run", t1]);
        driver("unknown target", "unknown target 'os2' (linux, win, kernel, web)", ["--target=os2", t1, "-o", o]);
    });
    foreach (f in yt.files(K, "e", ".y")) {
        let base = fs.path_stem(f);
        cs += yt.case_of(s, base, () => reject(f, base, true));
    };
    foreach (f in yt.files(K, "h", ".y")) {
        let base = fs.path_stem(f);
        cs += yt.case_of(s, base, () => reject(f, base, false));
    };
    cs
};

export { cases };
