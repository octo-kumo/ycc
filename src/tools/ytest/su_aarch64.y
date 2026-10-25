// AArch64 cross target: the native corpus, with the same output/exit/warning
// checks, run by qemu-user. Only fixtures explicitly tied to x86 are skipped.
import fs;
import yt;
import yc;
import su_native;

let ADIR = "";

def emulator() -> str { yt.env("QEMU_AARCH64", "qemu-aarch64") };

def fixture(file: str, base: str) {
    if (!yt.have(emulator())) { yt.skip(base, "no " + emulator()); return; };
    let skip = file[0:file.length - 2] + ".skip.aarch64";
    if (fs.is_file(skip)) { yt.skip(base, yt.read(skip).trim()); return; };
    su_native.DIR = ADIR;
    su_native.positive_for(file, base, ["--target=linux", "--arch=aarch64"], [emulator()]);
};

def driver() {
    let dir = yt.tmp_dir("arm-driver");
    let src = dir + "/probe.y";
    let bin = dir + "/probe";
    yt.write(src, "puts(\"aarch64\\n\");\n");
    foreach (flags in [["--target=linux", "--arch=aarch64"], ["--target", "linux", "--arch", "aarch64", "-g"]]) {
        let c = yc.compile(yc.YCC, flags, src, bin, 30);
        yt.check("AArch64 driver accepts target", c.code == 0, yt.clip(c.out, 200));
        let seed = yc.compile(yc.CYCC, flags, src, dir + "/seed", 30);
        yt.check("C and Y emit identical AArch64 images", seed.code == 0 && yt.same_file(bin, dir + "/seed"), yt.clip(seed.out, 200));
        let b = fs.read_bytes(bin);
        if (b == none || b!.length < 120) { yt.fail("AArch64 ELF", "missing image"); continue; };
        let image = b!;
        yt.check("ELF64 little-endian EM_AARCH64", image[4] == 2 && image[5] == 1 && image[18] == 183 && image[19] == 0, "wrong ELF header");
        if (yt.have(emulator())) {
            let run = yt.cmd([emulator(), bin]);
            let r = yt.run(run);
            yt.check("AArch64 image executes", r.code == 0 && r.out == "aarch64\n", yt.clip(r.out + r.err, 200));
        };
    };
    let s = yc.compile(yc.YCC, ["--target=linux", "--arch=aarch64", "--emit=asm"], src, dir + "/probe.s", 30);
    let listing = yt.read(dir + "/probe.s");
    yt.check("--emit=asm lowers AArch64 instructions", s.code == 0 && listing.contains(".arch armv8-a") && !listing.contains("%rax"), yt.clip(s.out, 200));
    if (yt.have("clang")) {
        let c = yt.cmd(["clang", "--target=aarch64-linux-gnu", "-c", dir + "/probe.s", "-o", dir + "/probe.o"]);
        let r = yt.run(c);
        yt.check("AArch64 listing assembles independently", r.code == 0, yt.clip(r.err + r.out, 300));
    };
    fs.make_dirs(dir + "/dep");
    yt.write(dir + "/dep/y.toml", "[package]\nname = \"dep\"\nlib = \"lib.y\"\n");
    yt.write(dir + "/dep/lib.y", "def answer() -> long { 42 };\ndef arm_pid() -> bool { syscall(172) > 0 };\n");
    yt.write(dir + "/main.y", "import dep;\nprint(dep.answer(), \" \" , dep.arm_pid());\n");
    yt.write(dir + "/y.toml", "[package]\nname = \"probe\"\n[bin]\nprobe = \"main.y\"\n[dependencies]\ndep = { path = \"dep\" }\n");
    foreach (target in ["linux", "linux-aarch64"]) {
        let tflags = if (target == "linux-aarch64") { ["--target=linux", "--arch=aarch64"] } else { ["--target=linux"] };
        let c = yt.cmd([yc.YCC, "build"] + tflags + [dir]);
        let r = yt.run(c);
        yt.check("project builds for " + target, r.code == 0, yt.clip(r.out + r.err, 300));
    };
    let arm_bin = dir + "/build/linux-aarch64/probe";
    yt.check("project target directories are distinct", fs.is_file(arm_bin) && fs.is_file(dir + "/build/probe"), "missing project image");
    if (yt.have(emulator()) && fs.is_file(arm_bin)) {
        let r = yt.run(yt.cmd([emulator(), arm_bin]));
        yt.check("AArch64 target reaches package compilation", r.code == 0 && r.out == "42 true\n", yt.clip(r.out + r.err, 300));
    };
    foreach (name in ["t309_asm_sse_forms", "t421_sized_int_pointers", "t160_threads"]) {
        yc.port_check(ADIR + "/" + name + ".y", ["--target=linux", "--arch=aarch64", "-g"], "AArch64 C/Y parity", false);
    };
    fs.remove_all(dir);
};

// All codecs preserve argv, environment and exit status. Packing an existing
// image selects its architecture without depending on the driver's default.
def packing() {
    let dir = yt.tmp_dir("arm-pack");
    let src = dir + "/probe.y";
    yt.write(src, "import fs;\nlet a = argv(); print(a[1], \":\", fs.getenv(\"Y_ARM_PACK\")!); exit(7);\n");
    let plain = dir + "/plain";
    let c = yc.compile(yc.YCC, ["--target=linux", "--arch=aarch64"], src, plain, 30);
    yt.check("pack payload compiles", c.code == 0, c.out);
    foreach (method in ["store", "fixed", "lz", "dynamic"]) {
        foreach (input in [src, plain]) {
            let bin = dir + "/packed";
            let flags = if (input == src) { ["--target=linux", "--arch=aarch64"] } else { [] };
            let r = yc.compile(yc.YCC, flags + ["--pack=" + method], input, bin, 30);
            yt.check("pack " + method + " " + fs.path_basename(input), r.code == 0, r.out);
            if (r.code == 0 && yt.have(emulator())) {
                let cmd = yt.cmd([emulator(), bin, "arg"]);
                cmd.env = ["Y_ARM_PACK=value"];
                let run = yt.run(cmd);
                yt.check("packed AArch64 argv/env/exit " + method, run.code == 7 && run.out == "arg:value\n", yt.clip(run.out + run.err, 300));
            };
        };
    };
    fs.remove_all(dir);
};

def sealed_keys() {
    let dir = yt.tmp_dir("arm-keys");
    let src = dir + "/probe.y";
    let key = dir + "/key";
    let secret = "0123456789abcdef";
    yt.write(key, secret);
    yt.write(src, "def add(a: long, b: long) -> long { a + b }; print(add(2, 3), \"ARM_SEAL_MARKER_0123456789\");\n");
    foreach (fd in [false, true]) {
        let flags = ["--target=linux", "--arch=aarch64", "--obfuscate-key=" + key, "--obfuscate-seed=9", "--obfuscate-report"];
        if (fd) { flags += "--obfuscate-key-fd=0"; };
        let bin = dir + "/sealed";
        let c = yc.compile(yc.YCC, flags, src, bin, 30);
        yt.check("AArch64 sealed external key", c.code == 0 && c.out.contains("bytecode="), c.out);
        if (c.code != 0) { continue; };
        yt.check("AArch64 sealed literal absent", !yt.read(bin).contains("ARM_SEAL_MARKER_0123456789"), "plaintext marker remains");
        let again = yc.compile(yc.YCC, flags, src, dir + "/again", 30);
        yt.check("AArch64 seal reproducible", again.code == 0 && yt.same_file(bin, dir + "/again"), again.out);
        if (yt.have(emulator())) {
            let cmd = yt.cmd([emulator(), bin]);
            if (fd) { cmd.input = secret; };
            let run = yt.run(cmd);
            yt.check("AArch64 external key executes", run.code == 0 && run.out == "5ARM_SEAL_MARKER_0123456789\n", yt.clip(run.out + run.err, 300));
            if (fd) { cmd.input = "wrong-key-value!"; }
            else { yt.write(key, "wrong-key-value!"); };
            let wrong = yt.run(cmd);
            yt.check("AArch64 wrong key fails closed", wrong.code == 127, yt.clip(wrong.out + wrong.err, 300));
            yt.write(key, secret);
        };
    };
    fs.remove_all(dir);
};

// A real hosted compiler: meta generators must use its host while -o can
// select either architecture. The cross-build and both self-builds must agree.
def hosted() {
    if (!yt.have(emulator())) { yt.skip("AArch64 compiler", "no " + emulator()); return; };
    let dir = yt.tmp_dir("arm-host");
    let bare = dir + "/bare";
    let cc = dir + "/ycc";
    let c = yc.compile(yc.YCC, ["--target=linux", "--arch=aarch64", "--gc=never"], yc.ROOT + "/src/y/ycc.y", bare, 60);
    yt.check("AArch64 compiler cross-build", c.code == 0, yt.clip(c.out, 300));
    if (c.code != 0) { fs.remove_all(dir); return; };
    let attached = yc.attach_pack(bare, cc, yc.YCC);
    yt.check("AArch64 compiler carries both stubs and std pack", attached, "attach failed");
    if (!attached) { fs.remove_all(dir); return; };
    let empty = dir + "/empty";
    fs.make_dirs(empty);
    let src = dir + "/probe.y";
    yt.write(src, "import fs;\n#{ \"let answer = 42; print(answer, \\\" \\\", fs.is_file(\\\"missing\\\"));\" }#\n");
    foreach (target in ["aarch64", "linux"]) {
        let tflags = if (target == "aarch64") { ["--target=linux", "--arch=aarch64"] } else { ["--target=linux"] };
        let cmd = yt.cmd([emulator(), cc, "--gc=auto"] + tflags + [src, "-o", dir + "/probe"]);
        cmd.cwd = empty;
        cmd.timeout = 60;
        let r = yt.run(cmd);
        yt.check("AArch64 hosted meta and cross-compile " + target, r.code == 0, yt.clip(r.out + r.err, 300));
        if (r.code == 0) {
            let args = if (target == "aarch64") { [emulator(), dir + "/probe"] } else { [dir + "/probe"] };
            let run = yt.run(yt.cmd(args));
            yt.check("hosted output executes " + target, run.code == 0 && run.out == "42 false\n", yt.clip(run.out + run.err, 300));
        };
    };
    let packed = dir + "/packed-ycc";
    let pc = yc.compile(yc.YCC, ["--pack=lz"], cc, packed, 30);
    yt.check("pack AArch64 compiler", pc.code == 0, pc.out);
    if (pc.code == 0) {
        let cmd = yt.cmd([emulator(), packed, "--gc=auto", "--pack", src, "-o", dir + "/packed-probe"]);
        cmd.cwd = empty;
        cmd.timeout = 60;
        let r = yt.run(cmd);
        yt.check("detached packed AArch64 compiler packs a meta program", r.code == 0, yt.clip(r.out + r.err, 300));
        if (r.code == 0) {
            let run = yt.run(yt.cmd([emulator(), dir + "/packed-probe"]));
            yt.check("nested packed AArch64 output executes", run.code == 0 && run.out == "42 false\n", yt.clip(run.out + run.err, 300));
        };
    };
    foreach (gen in ["two", "three"]) {
        let cmd = yt.cmd([emulator(), cc, "--gc=never", yc.ROOT + "/src/y/ycc.y", "-o", dir + "/" + gen]);
        cmd.timeout = 60;
        let r = yt.run(cmd);
        yt.check("AArch64 self-compile " + gen, r.code == 0 && yt.same_file(bare, dir + "/" + gen), yt.clip(r.out + r.err, 300));
        if (r.code != 0) { break; };
        let next = dir + "/" + gen + ".packed";
        if (!yc.attach_pack(dir + "/" + gen, next, yc.YCC)) { yt.fail("AArch64 generation pack", "attach failed"); break; };
        cc = next;
    };
    fs.remove_all(dir);
};

def cases() -> [yt.Case] {
    ADIR = yc.ROOT + "/test/y/native";
    let cs = [yt.case_of("aarch64", "driver", () => driver()),
        yt.case_of("aarch64", "packing", () => packing()),
        yt.case_of("aarch64", "sealed keys", () => sealed_keys()),
        yt.case_of("aarch64", "hosted", () => hosted())];
    foreach (f in yt.files(ADIR, "t", ".y")) {
        let base = fs.path_stem(f);
        cs += yt.case_of("aarch64", base, () => fixture(f, base));
    };
    foreach (f in yt.files(yc.ROOT + "/test/aarch64", "t", ".y")) {
        let base = fs.path_stem(f);
        cs += yt.case_of("aarch64", base, () => {
            su_native.DIR = yc.ROOT + "/test/aarch64";
            yc.port_check(f, ["--target=linux", "--arch=aarch64"], "AArch64 C/Y parity", false);
            if (yt.have(emulator())) {
                su_native.positive_for(f, base, ["--target=linux", "--arch=aarch64"], [emulator()]);
            } else { yt.skip(base, "no " + emulator()); };
        });
    };
    cs
};
export { cases };
