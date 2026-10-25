// su_gui.y -- std/gui against a real window system.
//
// The headless window (test/y/native/t435_gui_headless.y) and the Win32 window (test/pe/guiwin.y,
// `ytest pe-fixtures`) are checked elsewhere. Here the X11 backend meets an X server: the window
// is opened, what is presented is what the server holds (GetImage), a resize comes back as an
// event, and what a person does with it -- typing, a click, the wheel, the window manager's
// close -- comes back as events (xdotool plays the person, python-xlib the window manager).
//
// The X server is $GUI_DISPLAY (a display that is up, ":0"), else one started for the run: Xvfb,
// or Xwayland under a headless weston. Without any of them, or without xdotool and python-xlib
// for the input half, the parts that need them are skipped with the reason.
import fs;
import yt;
import yc;

let W = "";

def compiler() -> str { if (yc.have_ycc()) { yc.YCC } else { yc.CYCC } };

// A display number no other run is likely to use, and the socket that says it is up.
def socket_up(n: long) -> bool { fs.exists("/tmp/.X11-unix/X" + tostring(n)) };

def wait_socket(n: long, secs: long) -> bool {
    let i = 0;
    while (i < secs * 10 && !socket_up(n)) {
        yt.sleep_us(100000);
        i += 1;
    };
    socket_up(n)
};

type Server = { display: str, procs: [yt.Proc] };

// A socket can exist while the server has already died (a broken DRM driver
// aborts Xvfb): ask the server itself before treating the display as up.
def display_ok(d: str) -> bool {
    if (!yt.have("xdotool")) { return true; };
    let c = yt.cmd(["xdotool", "getdisplaygeometry"]);
    c.merge = true;
    c.timeout = 10;
    c.env = ["DISPLAY=" + d];
    yt.run(c).code == 0
};

// Start an X server for the run; display "" when there is none to be had.
def x_server() -> Server {
    let procs: [yt.Proc] = [];
    let ext = yt.env("GUI_DISPLAY", "");
    if (ext != "") { return { display: ext, procs: procs }; };
    let n = 90 + yt.getpid() % 100;
    if (yt.have("Xvfb")) {
        let c = yt.cmd(["Xvfb", ":" + tostring(n), "-screen", "0", "1024x768x24", "-nolisten", "tcp", "-ac"]);
        c.timeout = 120;
        c.merge = true;
        procs += yt.start(c);
        if (wait_socket(n, 8) && display_ok(":" + tostring(n))) { return { display: ":" + tostring(n), procs: procs }; };
    };
    if (yt.have("weston") && yt.have("Xwayland")) {
        let rt = W + "/xdg";
        fs.make_dirs(rt);
        yt.exe(["chmod", "700", rt]);
        let sock = "ytest-wl-" + tostring(n);
        let wc = yt.cmd(["weston", "--backend=headless", "--socket=" + sock, "--width=1024", "--height=768"]);
        wc.timeout = 120;
        wc.merge = true;
        wc.env = ["XDG_RUNTIME_DIR=" + rt];
        procs += yt.start(wc);
        let i = 0;
        while (i < 80 && !fs.exists(rt + "/" + sock)) {
            yt.sleep_us(100000);
            i += 1;
        };
        let xc = yt.cmd(["Xwayland", ":" + tostring(n), "-geometry", "1024x768", "-ac", "-noreset"]);
        xc.timeout = 120;
        xc.merge = true;
        xc.env = ["XDG_RUNTIME_DIR=" + rt, "WAYLAND_DISPLAY=" + sock];
        procs += yt.start(xc);
        if (wait_socket(n, 10) && display_ok(":" + tostring(n))) { return { display: ":" + tostring(n), procs: procs }; };
    };
    foreach (p in procs) { yt.kill(p); yt.wait(p); };
    { display: "", procs: [] }
};

def stop_server(s: Server) {
    foreach (p in s.procs) {
        yt.kill(p);
        yt.wait(p);
    };
};

def build(name: str) -> str {
    let out = W + "/" + name;
    let r = yc.compile(compiler(), [], yc.ROOT + "/test/gui/" + name + ".y", out, 60);
    if (r.code != 0) {
        yt.fail("build " + name, yt.clip(r.out, 300));
        return "";
    };
    // the two copies of the compiler write the same bytes
    let c = yc.compile(yc.CYCC, [], yc.ROOT + "/test/gui/" + name + ".y", out + ".c", 60);
    yt.check("compiler parity " + name, c.code == 0 && yt.same_file(out, out + ".c"), yt.clip(c.out, 200));
    out
};

def window_case(srv: Server) {
    let bin = build("x11");
    if (bin == "") { return; };
    let c = yt.cmd([bin]);
    c.merge = true;
    c.timeout = 30;
    c.mem_kb = yc.PROG_MEM_KB;
    c.env = ["DISPLAY=" + srv.display];
    let r = yt.run(c);
    let want = yt.read(yc.ROOT + "/test/gui/x11.expected");
    yt.check("x11 window", r.out == want, yt.first_diff(want, r.out));
};

def input_case(srv: Server) {
    if (!yt.have("xdotool")) {
        yt.skip("x11 input", "no xdotool to play the person");
        return;
    };
    if (!yt.have("python3")) {
        yt.skip("x11 input", "no python3 to play the window manager");
        return;
    };
    let bin = build("x11_input");
    if (bin == "") { return; };
    let outp = W + "/input.out";
    let c = yt.cmd([bin]);
    c.merge = true;
    c.timeout = 40;
    c.mem_kb = yc.PROG_MEM_KB;
    c.out = outp;
    c.env = ["DISPLAY=" + srv.display];
    let p = yt.start(c);
    let i = 0;
    while (i < 100 && !yt.read(outp).contains("ready")) {
        yt.sleep_us(100000);
        i += 1;
    };
    let env = ["DISPLAY=" + srv.display];
    let steps: [[str]] = [["mousemove", "40", "50"], ["key", "a"], ["key", "shift+b"], ["key", "ctrl+c"], ["key", "Left"],
        ["key", "Return"], ["key", "Escape"], ["key", "BackSpace"], ["click", "1"], ["click", "3"], ["click", "4"], ["click", "5"]];
    foreach (s in steps) {
        let xc = yt.cmd(["xdotool"] + s);
        xc.env = env;
        xc.timeout = 10;
        yt.run(xc);
        yt.sleep_us(120000);
    };
    yt.sleep_us(300000);
    // the window manager's close button
    let pc = yt.cmd(["python3", yc.ROOT + "/test/gui/xclose.py", "ytest gui x11 input"]);
    pc.env = env;
    pc.merge = true;
    pc.timeout = 20;
    let pr = yt.run(pc);
    if (pr.code != 0 && pr.out.contains("No module named")) {
        yt.kill(p);
        yt.wait(p);
        yt.skip("x11 input", "python-xlib is not installed");
        return;
    };
    yt.wait(p);
    let want = yt.read(yc.ROOT + "/test/gui/x11_input.expected");
    let got = yt.read(outp);
    yt.check("x11 input", got == want, yt.first_diff(want, got));
};

def x11() {
    W = yt.tmp_dir("gui");
    let srv = x_server();
    if (srv.display == "") {
        yt.skip("x11 window", "no X server: set GUI_DISPLAY or install Xvfb (or weston and Xwayland)");
        fs.remove_all(W);
        return;
    };
    window_case(srv);
    input_case(srv);
    stop_server(srv);
    fs.remove_all(W);
};

// One case: the programs share one X server, and it starts and stops with them.
def cases() -> [yt.Case] {
    [yt.case_of("gui", "x11", x11)]
};

export { cases };
