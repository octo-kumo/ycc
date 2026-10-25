// yos.y -- Y-OS: build it, boot it, drive a shell session on it.
//
//   ytest os-build [YCC] [OUT]   the kernel (OUT/os.img) and its filesystem
//                                (OUT/os.fs: what os/manifest.txt lists);
//                                YCC defaults to ./ycc, OUT to os/build
//   ytest os-run                 boot it with the serial console on this terminal
//                                (Ctrl-A X leaves qemu; `halt` stops the machine);
//                                the terminal's size goes in as rows=/cols= on the
//                                kernel command line;  `--gui` boots with a screen
//                                (OS_VGA=virtio|std) and keyboard/mouse instead
//
// Every boot has 512 MB and an AC97 card whose audio backend is $OS_AUDIO
// (default `none`, `pa` for run-os; `wav,path=/x.wav` records, `pipewire` plays).
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
import ipc;
import crypto;

def qemu() -> str { yt.env("QEMU", "qemu-system-x86_64") };

/** The machine every boot gets: memory, the exit device, the sound card. */
def machine(audio: str) -> [str] {
    ["-no-reboot", "-device", "isa-debug-exit", "-m", "512",
     "-device", "AC97,audiodev=a0", "-audiodev", (if (audio != "") { audio } else { yt.env("OS_AUDIO", "none") }) + ",id=a0"]
};

/** The host sound backend of an interactive boot: PipeWire when its socket is there (qemu's pa backend
fails its volume calls against pipewire-pulse and plays nothing), else PulseAudio. */
def host_audio() -> str {
    let dir = yt.env("XDG_RUNTIME_DIR", "");
    if (dir != "" && fs.exists(dir + "/pipewire-0")) { return "pipewire"; };
    "pa"
};

/** The display and input devices of a boot with a screen: the standard VGA with PS/2 input, or
virtio-gpu with virtio keyboard and tablet. */
def gui_devices(kind: str) -> [str] {
    if (kind == "virtio") {
        return ["-vga", "none", "-device", "virtio-gpu-pci", "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci"];
    };
    ["-vga", "std"]
};

type Entry = { dest: str, kind: str, src: str, flags: [str] };

/** `$NAME` in `s` from the environment (unset is empty). */
def expand(s: str) -> str {
    let out = "";
    let i = 0;
    while (i < s.length) {
        if (s[i] == 36) {
            let j = i + 1;
            while (j < s.length && ((s[j] >= 65 && s[j] <= 90) || (s[j] >= 48 && s[j] <= 57) || s[j] == 95)) { j += 1; };
            let name = s[i + 1:j];
            out += yt.env(name, "");
            i = j;
        } else {
            out += chr(s[i]);
            i += 1;
        };
    };
    out
};

/** os/manifest.txt, parsed: comments and blank lines dropped. */
def manifest() -> [Entry] {
    let out: [Entry] = [];
    foreach (ln in yt.lines(yt.read(yc.ROOT + "/os/manifest.txt"))) {
        let t = ln.trim();
        if (t.length > 0 && t[0] != 35) {
            let w: [str] = [];
            foreach (x in t.split(" ")) { if (x.length > 0) { w += x; }; };
            if (w.length >= 3) {
                let e: Entry = { dest: w[0], kind: w[1], src: expand(w[2]), flags: w[3:] };
                out += e;
            };
        };
    };
    out
};

def has_flag(e: Entry, f: str) -> bool {
    let yes = false;
    foreach (x in e.flags) { if (x == f) { yes = true; }; };
    yes
};

/** The value of flag `key=` on `e`, or "". */
def flag_val(e: Entry, key: str) -> str {
    let v = "";
    foreach (x in e.flags) { if (x.starts_with(key + "=")) { v = x[key.length + 1:]; }; };
    v
};

def rooted(p: str) -> str { if (p.starts_with("/")) { p } else { yc.ROOT + "/" + p } };

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
    let e = one(["--target=kernel", "os/kernel/boot.y", "-o", out + "/os.img"]);
    if (e == "") { e = one(["os/tools/mkfs.y", "-o", out + "/mkfs"]); };
    let args: [str] = [out + "/mkfs", out + "/os.fs"];
    let n = 0;
    foreach (m in manifest()) {
        let name = if (m.dest.starts_with("/")) { m.dest[1:] } else { m.dest };
        let prod = out + "/files/" + tostring(n) + "_" + name.replace("/", "_");
        n += 1;
        let flags: [str] = [];
        foreach (x in m.flags) { if (x != "optional" && !x.starts_with("out=")) { flags += x; }; };
        let src = if (m.kind == "uland") { yc.ROOT + "/os/uland/" + m.src } else { rooted(m.src) };
        if (e != "") {
            // an earlier step failed
        } else if (m.kind == "dir") {
            args += "-d";
            args += name;
        } else if (!fs.exists(src)) {
            if (has_flag(m, "optional")) {
                eputs("os: skipping " + m.dest + " (no " + src + ")\n");
            } else {
                e = "manifest: " + m.dest + ": no " + src;
            };
        } else {
            if (m.kind == "file") {
                prod = src;
            } else if (m.kind == "build") {
                let c = yt.cmd([cc, "build"] + flags);
                c.cwd = src;
                c.merge = true;
                c.timeout = 600 * yt.SCALE;
                let r = yt.run(c);
                if (r.code != 0) { e = "ycc build in " + src + ": " + r.out; };
                prod = src + "/" + flag_val(m, "out");
                if (e == "" && flag_val(m, "out") == "") { e = "manifest: " + m.dest + ": a build entry needs out=PATH"; };
            } else if (m.kind == "uland" || m.kind == "y") {
                fs.make_dirs(out + "/files");
                e = one([src] + flags + ["-o", prod]);
            } else {
                e = "manifest: " + m.dest + ": unknown kind " + m.kind;
            };
            args += name;
            args += prod;
        };
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
def session(img: str, fsimg: str, cmds: [str], secs: long, ok: [bool], audio: str) -> str {
    let p = spawn([qemu(), "-kernel", img, "-initrd", fsimg, "-serial", "stdio", "-display", "none", "-vga", "none"] + machine(audio));
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


// ── display sessions ────────────────────────────────────────────────────
// test/os/display/NAME.steps boots Y-OS with a screen and drives it through QEMU's monitor; one
// step a line:  boot std|virtio (first line)   wait SECONDS   await TEXT (until the serial console
// has printed it)   type TEXT   key KEY (a monitor key name: f12, ret, left)   move DX DY   click
// shot NAME (a screendump). NAME.expected has one `NAME SHA256` line per shot; YBLESS=1 writes it.

/** The monitor's key name for one typed character. */
def key_name(c: long) -> str {
    if (c == 32) { return "spc"; };
    if (c == 10) { return "ret"; };
    if (c == 47) { return "slash"; };
    if (c == 46) { return "dot"; };
    if (c == 45) { return "minus"; };
    if (c == 95) { return "shift-minus"; };
    if (c == 44) { return "comma"; };
    if (c == 59) { return "semicolon"; };
    if (c == 61) { return "equal"; };
    if (c == 43) { return "shift-equal"; };
    if (c == 42) { return "shift-8"; };
    if (c == 36) { return "shift-4"; };
    if (c == 62) { return "shift-dot"; };
    if (c == 60) { return "shift-comma"; };
    if (c == 124) { return "shift-backslash"; };
    if (c == 58) { return "shift-semicolon"; };
    if (c >= 65 && c <= 90) { return "shift-" + chr(c + 32); };
    chr(c)
};

/** Boot with a screen, run `steps`; the `NAME HASH` line of every shot. ok[0]: it all ran. */
def display_session(img: str, fsimg: str, steps: [str], dir: str, ok: [bool]) -> [str] {
    let kind = "std";
    if (steps.length > 0 && steps[0].starts_with("boot ")) { kind = steps[0][5:]; };
    let sock = dir + "/mon.sock";
    let p = spawn([qemu(), "-kernel", img, "-initrd", fsimg, "-serial", "stdio", "-display", "none",
        "-monitor", "unix:" + sock + ",server,nowait"] + gui_devices(kind) + machine(""));
    let out: [byte] = [];
    let got: [str] = [];
    let buf: [byte; 4096] = [0; 4096];
    let pfd: [long; 1] = [0; 1];
    let tries = 0;
    while (!fs.exists(sock) && tries < 100) {
        syscall(7, &pfd[0], 0, 50);
        tries += 1;
    };
    let mon = ipc.connect_unix(sock);
    let good = mon >= 0;
    // read the serial console for `ms` milliseconds
    def pump(ms: long) {
        let end = clock_us() + ms * 1000;
        while (clock_us() < end) {
            pfd[0] = p[2] + 4294967296;
            let left = (end - clock_us()) / 1000;
            if (left > 0 && syscall(7, &pfd[0], 1, if (left < 50) { left } else { 50 }) > 0) {
                let k = syscall(0, p[2], &buf[0], 4096);
                if (k > 0) { out += buf[0:k]; };
            };
        };
    };
    def hmp(c: str) {
        ipc.send(mon, bytes(c + "\n"));
        pump(120);
        while (ipc.wait_readable(mon, 0)) {
            if (ipc.recv_some(mon, 4096) == none) { break; };
        };
    };
    def seen(t: str) -> bool { from_bytes(out).contains(t) };
    if (good) {
        let n = 0;
        while (!seen("user:/home/user$ ") && n < 600) { pump(100); n += 1; };
        good = seen("user:/home/user$ ");
        // the desktop starts after the shell's first prompt: give it time to draw
        pump(4000);
    };
    let i = 1;
    while (good && i < steps.length) {
        let st = steps[i];
        let sp = st.index_of(" ");
        let verb = if (sp < 0) { st } else { st[0:sp] };
        let arg = if (sp < 0) { "" } else { st[sp + 1:] };
        if (verb == "wait") { pump(yt.num(arg, 1) * 1000); }
        else if (verb == "key") { hmp("sendkey " + arg); }
        else if (verb == "type") {
            let k = 0;
            while (k < arg.length) { hmp("sendkey " + key_name(arg[k])); k += 1; };
        }
        else if (verb == "move") { hmp("mouse_move " + arg); }
        else if (verb == "click") { hmp("mouse_button 1"); pump(80); hmp("mouse_button 0"); }
        else if (verb == "await") {
            let n = 0;
            while (!seen(arg) && n < 200) { pump(100); n += 1; };
            if (!seen(arg)) { good = false; };
        }
        else if (verb == "shot") {
            hmp("screendump " + dir + "/" + arg + ".ppm");
            pump(400);
            let b = fs.read_bytes(dir + "/" + arg + ".ppm");
            if (b == none) { good = false; } else { got += arg + " " + crypto.hex(crypto.sha256(b!)); };
        };
        i += 1;
    };
    // YOSLOG=FILE: what the serial console said, for a display session that went wrong
    if (yt.env("YOSLOG", "") != "") { fs.write_bytes(yt.env("YOSLOG", ""), out); };
    if (mon >= 0) {
        ipc.send(mon, bytes("quit\n"));
        ipc.close(mon);
    };
    syscall(62, p[0], 9);
    let st: [long; 1] = [0; 1];
    syscall(61, p[0], &st[0], 0, 0);
    syscall(3, p[1]);
    syscall(3, p[2]);
    ok[0] = good;
    got
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
    // the host terminal's size (TIOCGWINSZ on stdout), for the kernel's tty
    let ws: [long; 1] = [0; 1];
    let rows = 24;
    let cols = 80;
    if (syscall(16, 1, 21523, &ws[0]) == 0 && (ws[0] & 65535) > 0) {
        rows = ws[0] & 65535;
        cols = (ws[0] >> 16) & 65535;
    };
    let gui = false;
    let i = 0;
    while (i < av.length) {
        if (av[i] == "--gui") { gui = true; };
        i += 1;
    };
    // serial on this terminal, no display (the tty is this terminal's size); `--gui` opens a
    // window instead and the screen is the console (F1 or F12 flips terminal and GUI): OS_VGA=virtio (the default:
    // the host can resize it, the pointer is absolute) or std
    let screen = ["-display", "none", "-vga", "none", "-append", "rows=" + tostring(rows) + " cols=" + tostring(cols)];
    if (gui) { screen = gui_devices(yt.env("OS_VGA", "virtio")); };
    let c = yt.cmd([qemu(), "-kernel", "os/build/os.img", "-initrd", "os/build/os.fs", "-serial", "mon:stdio"] + screen + machine(yt.env("OS_AUDIO", host_audio())));
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
    puts(session(img, fsimg, cmds, secs, ok, ""));
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
        // a sibling NAME.wav marks a session that must make sound: qemu records it
        let wav = "";
        if (fs.exists(yc.ROOT + "/test/os/" + name + ".wav")) { wav = w + "/" + name + ".wav"; };
        let got = session(w + "/y/os.img", w + "/y/os.fs", yt.lines(yt.read(f)), 90 * yt.SCALE, ok, if (wav != "") { "wav,path=" + wav } else { "" });
        let want = yt.read(yc.ROOT + "/test/os/" + name + ".expected");
        if (!ok[0]) {
            let ls = yt.lines(got);
            yt.fail(name + ": the session ran to a halt", "transcript ends: " + yt.clip(join(ls[if (ls.length > 3) { ls.length - 3 } else { 0 }:], "\n"), 300));
        } else {
            yt.check(name + ": transcript matches", yt.lines(got) == yt.lines(want), yt.clip(got, 3000));
            if (wav != "") { yt.check(name + ": the wav has sound", wav_has_sound(wav), "the recording is silent or missing"); };
        };
    };
    foreach (f in yt.files(yc.ROOT + "/test/os/display", "", ".steps")) {
        let name = fs.path_stem(f);
        // YDISPLAY=name runs one display fixture
        if (yt.env("YDISPLAY", "") != "" && yt.env("YDISPLAY", "") != name) { continue; };
        let ok = [false];
        let dd = w + "/disp-" + name;
        fs.make_dirs(dd);
        let got = display_session(w + "/y/os.img", w + "/y/os.fs", yt.lines(yt.read(f)), dd, ok);
        let exp = yc.ROOT + "/test/os/display/" + name + ".expected";
        if (!ok[0]) {
            yt.fail("display " + name + ": the session ran", "a step failed (no prompt, a missing screendump or a text never printed)");
        } else if (yt.env("YBLESS", "") != "") {
            yt.write(exp, join(got, "\n") + "\n");
            yt.pass("display " + name + ": blessed " + tostring(got.length) + " shots");
        } else {
            let want = yt.lines(yt.read(exp));
            let same = true;
            let k = 0;
            while (k < got.length) {
                if (k >= want.length || want[k] != got[k]) { same = false; };
                k += 1;
            };
            if (!same) {
                fs.make_dirs(yc.ROOT + "/_check/os-display");
                foreach (g in got) {
                    let nm = g[0:g.index_of(" ")];
                    fs.write_bytes(yc.ROOT + "/_check/os-display/" + name + "-" + nm + ".ppm", fs.read_bytes(dd + "/" + nm + ".ppm")!);
                };
            };
            yt.check("display " + name + ": the screenshots match", same, "differs from " + exp + "; the pictures are in _check/os-display: " + yt.clip(join(got, " | "), 600));
        };
    };
    fs.remove_all(w);
};

/** Does the 16-bit PCM after the 44-byte header of `path` hold a non-zero sample? */
def wav_has_sound(path: str) -> bool {
    let b = fs.read_bytes(path);
    if (b == none) { return false; };
    let d = b!;
    let i = 44;
    let found = false;
    while (!found && i < d.length) {
        if (d[i] != 0) { found = true; };
        i += 1;
    };
    found
};

def cases() -> [yt.Case] { [yt.case_of("os", "os", suite)] };

export { cases, main_build, main_run, main_session };
