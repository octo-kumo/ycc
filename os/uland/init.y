// init -- the first process: the environment, the directories every program expects,
// the sound server and the desktop in the background, then the shell. It stays to reap orphans, and
// when the shell is gone it stops the machine.
import ulib;

let env = ["HOME=/home/user", "USER=user", "PATH=/bin", "TERM=xterm-256color", "XDG_RUNTIME_DIR=/run/user/1000"];

// makes the directory `p` and the ones above it; a failure (it exists, or a kernel
// without directories) is not worth stopping for
def make_path(p: str) -> void {
    let k = 1;
    while (k <= len(p)) {
        if (k == len(p) || p[k] == 47) {
            let pre = p[0:k];
            if (!ulib.is_dir(pre)) { ulib.mkdir(pre); };
        };
        k = k + 1;
    };
};

/** Start `path` as a child in the background (stdin, stdout, stderr as they are); its pid. */
def spawn(path: str, args: [str]) -> long {
    let pid = ulib.fork();
    if (pid == 0) {
        ulib.exec(path, args, env);
        exit(127);
    };
    pid
};

make_path("/tmp");
make_path("/run/user/1000");
make_path("/home/user");
if (ulib.exists("/bin/pulsed")) { spawn("/bin/pulsed", ["pulsed"]); };
// the desktop, when there is a display (a machine with only the serial console opens no /dev/fb0)
if (ulib.exists("/bin/desktop")) {
    let fb = ulib.open("/dev/fb0", 2);
    if (fb >= 0) {
        ulib.close(fb);
        spawn("/bin/desktop", ["desktop"]);
    };
};
ulib.chdir("/home/user");
let sh = spawn("/bin/sh", ["sh"]);
if (sh < 0) {
    puts("init: cannot start /bin/sh\n");
    ulib.halt();
};
let st: [long; 1] = [0; 1];
let alive = true;
while (alive) {
    let w = ulib.wait_pid(-1, st, 0);
    if (w == sh || w < 0) { alive = false; };
};
puts("bye\n");
ulib.halt();
