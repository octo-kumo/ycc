// yos.y -- Y-OS: build it, boot it, drive a shell session on it.
//
//   ytest os-build [YCC] [OUT]   the kernel (OUT/os.img) and its filesystem
//                                (OUT/os.fs: the shell and its programs);
//                                YCC defaults to ./ycc, OUT to os/build
//   ytest os-run                 boot it with the serial console on this terminal
//                                (Ctrl-A X leaves qemu; `halt` stops the machine)
//   ytest os-session [--timeout S] [--img I] [--fs F] CMD...
//                                boot, send one command line at a time, each
//                                only after the shell printed its prompt, and
//                                print the transcript; exit 0 when every command
//                                got its prompt back and the machine halted
//
// And the `os` suite: both engines build the same image and filesystem, and
// each scripted session in test/os (NAME.cmds, one line per command, the last
// one halting) matches NAME.expected.
import fs;
import yt;
import yc;

let PROGS = ["sh", "ls", "cat", "echo", "wc", "head", "cp", "rm", "mv", "write", "halt", "pwd"];

def qemu() -> str { yt.env("QEMU", "qemu-system-x86_64") };

/** Build Y-OS with `ycc` into `out`: "" when it worked, else what failed. */
def build(ycc: str, out: str) -> str {
    fs.make_dirs(out);
    let cc = yc.abs_path(ycc);
    def one(args: [str]) -> str {
        let c = yt.cmd([cc] + args);
        c.cwd = yc.ROOT;
        c.merge = true;
        c.timeout = 300 * yt.SCALE;
        let r = yt.run(c);
        if (r.code != 0) { "ycc " + join(args, " ") + ": " + r.out } else { "" }
    };
    let e = one(["--kernel", "os/kernel/boot.y", "-o", out + "/os.img"]);
    if (e == "") { e = one(["os/tools/mkfs.y", "-o", out + "/mkfs"]); };
    let args: [str] = [out + "/mkfs", out + "/os.fs"];
    foreach (p in PROGS) {
        if (e == "") { e = one(["os/uland/" + p + ".y", "-o", out + "/" + p]); };
        args += p;
        args += out + "/" + p;
    };
    if (e != "") { return e; };
    let m = yt.exe2(args);
    if (m.code != 0) { return "mkfs: " + m.out; };
    ""
};

// A child on two pipes: [pid, its stdin's write end, its stdout's read end].
def spawn(argv: [str]) -> [long] {
    let a: [long; 1] = [0; 1];
    let b: [long; 1] = [0; 1];
    syscall(293, &a[0], 524288);
    syscall(293, &b[0], 524288);
    let in_r = a[0] & 4294967295;
    let in_w = a[0] >> 32;
    let out_r = b[0] & 4294967295;
    let out_w = b[0] >> 32;
    let keep: [[byte]] = [];
    let av: [long] = [];
    foreach (s in argv) {
        keep += [yt.cz(s)];
        av += ptr_addr(&keep[keep.length - 1][0]);
    };
    av += 0;
    let ev: [long] = [];
    foreach (e in yt.environ()) {
        keep += [yt.cz(e)];
        ev += ptr_addr(&keep[keep.length - 1][0]);
    };
    ev += 0;
    let path = yt.cz(yt.which(argv[0], yt.env("PATH", "/usr/bin:/bin")));
    let null = yt.cz("/dev/null");
    let pid = syscall(57);
    if (pid == 0) {
        syscall(33, in_r, 0);
        syscall(33, out_w, 1);
        let n = syscall(2, &null[0], 1, 0);
        syscall(33, n, 2);
        syscall(59, &path[0], ptr_addr(&av[0]), ptr_addr(&ev[0]));
        syscall(231, 127);
    };
    syscall(3, in_r);
    syscall(3, out_w);
    [pid, in_w, out_r]
};

/** Boot img+fs, feed `cmds` one per prompt: the transcript, and in ok[0]
whether every command was sent and the machine halted in time. */
def session(img: str, fsimg: str, cmds: [str], secs: long, ok: [bool]) -> str {
    let p = spawn([qemu(), "-kernel", img, "-initrd", fsimg, "-serial", "stdio", "-display", "none", "-no-reboot",
                   "-device", "isa-debug-exit", "-m", "128"]);
    let out: [byte] = [];
    let sent = 0;
    let deadline = clock_us() + secs * 1000000;
    let buf: [byte; 4096] = [0; 4096];
    let pfd: [long; 1] = [0; 1];
    let in_time = true;
    let go = true;
    while (go) {
        let left = (deadline - clock_us()) / 1000;
        if (left <= 0) {
            in_time = false;
            go = false;
        } else {
            pfd[0] = p[2] + 4294967296;
            if (syscall(7, &pfd[0], 1, if (left < 200) { left } else { 200 }) > 0) {
                let k = syscall(0, p[2], &buf[0], 4096);
                if (k <= 0) { go = false; } else { out += buf[0:k]; };
            };
            // a prompt at the end of the output: the shell waits for a line
            let n = out.length;
            if (go && sent < cmds.length && n >= 2 && out[n - 2] == 36 && out[n - 1] == 32) {
                let line = cmds[sent] + "\r";
                syscall(1, p[1], line, line.length);
                sent += 1;
            };
        };
    };
    syscall(62, p[0], 9);
    let st: [long; 1] = [0; 1];
    syscall(61, p[0], &st[0], 0, 0);
    syscall(3, p[1]);
    syscall(3, p[2]);
    ok[0] = in_time && sent == cmds.length;
    from_bytes(out).replace("\r\n", "\n")
};

def main_build(av: [str]) -> long {
    let ycc = if (av.length > 0) { av[0] } else { "./ycc" };
    let out = if (av.length > 1) { av[1] } else { yt.env("OSOUT", "os/build") };
    let e = build(ycc, yc.abs_path(out));
    if (e != "") {
        eputs("os: " + e);
        return 1;
    };
    print("os: built " + out + "/os.img (" + tostring(yt.size(yc.abs_path(out) + "/os.img")) + " bytes) and " + out
        + "/os.fs (" + tostring(yt.size(yc.abs_path(out) + "/os.fs")) + " bytes)");
    0
};

def main_run(av: [str]) -> long {
    if (!fs.is_file(yc.ROOT + "/os/build/os.img") && main_build([]) != 0) { return 1; };
    let c = yt.cmd([qemu(), "-kernel", "os/build/os.img", "-initrd", "os/build/os.fs", "-serial", "mon:stdio", "-display", "none",
                    "-no-reboot", "-device", "isa-debug-exit", "-m", "128"]);
    c.cwd = yc.ROOT;
    c.tty = true;
    c.timeout = 0;
    c.mem_kb = 0;
    yt.run(c).code
};

def main_session(av: [str]) -> long {
    let secs = 60;
    let img = "os/build/os.img";
    let fsimg = "os/build/os.fs";
    let cmds: [str] = [];
    let i = 0;
    while (i < av.length) {
        if (av[i] == "--timeout" && i + 1 < av.length) { secs = yt.num(av[i + 1], 60); i += 1; }
        else if (av[i] == "--img" && i + 1 < av.length) { img = av[i + 1]; i += 1; }
        else if (av[i] == "--fs" && i + 1 < av.length) { fsimg = av[i + 1]; i += 1; }
        else { cmds += av[i]; };
        i += 1;
    };
    let ok = [false];
    puts(session(img, fsimg, cmds, secs, ok));
    if (ok[0]) { 0 } else { 1 }
};

def suite() {
    if (!yt.have(qemu())) {
        yt.skip("os: no " + qemu() + ", the whole suite", "install qemu-system-x86_64");
        return;
    };
    let w = yt.tmp_dir("os");
    let e = build(yc.YCC, w + "/y");
    if (e != "") {
        yt.fail("os builds with the built compiler", yt.clip(e, 300));
        return;
    };
    yt.pass("os builds with the built compiler");
    let c = build(yc.CYCC, w + "/c");
    if (c != "") {
        yt.fail("os builds with the C copy", yt.clip(c, 300));
    } else {
        yt.check("os: the two engines build the same kernel image and filesystem",
            yt.same_file(w + "/y/os.img", w + "/c/os.img") && yt.same_file(w + "/y/os.fs", w + "/c/os.fs"),
            "os.img or os.fs differ between the engines");
    };
    foreach (f in yt.files(yc.ROOT + "/test/os", "", ".cmds")) {
        let name = fs.path_stem(f);
        let ok = [false];
        let got = session(w + "/y/os.img", w + "/y/os.fs", yt.lines(yt.read(f)), 90 * yt.SCALE, ok);
        let want = yt.read(yc.ROOT + "/test/os/" + name + ".expected");
        if (!ok[0]) {
            let ls = yt.lines(got);
            yt.fail(name + ": the session ran to a halt", "transcript ends: " + yt.clip(join(ls[if (ls.length > 3) { ls.length - 3 } else { 0 }:], "\n"), 300));
        } else {
            yt.check(name + ": transcript matches", yt.lines(got) == yt.lines(want), yt.clip(got, 300));
        };
    };
    fs.remove_all(w);
};

def cases() -> [yt.Case] { [yt.case_of("os", "os", suite)] };

export { cases, main_build, main_run, main_session };
