// sh -- the Y-OS shell.
//
//   sh            interactive: a prompt (user:/home/user$ ), one line at a time
//   sh -c LINE    run LINE and exit with its status
//   sh FILE       run the lines of FILE
//
// A line is words, split on blanks, with 'single' and "double" quotes and the
// backslash; $NAME, ${NAME}, $? and $$ expand outside single quotes; a word that
// starts with ~ is the home directory. Operators: | pipes, < > >> 2> 2>> redirect,
// ; && || sequence, & runs in the background; # starts a comment.
//
// Built in: cd pwd export unset exit env help true false and NAME=value. Any other
// word is a program: with a / in it, that path; otherwise the first match in the
// directories of $PATH. Programs run in their own process group and, from a
// terminal, in the foreground of it.
//
// Reading: on a terminal in canonical mode the shell edits the line itself (edit_line):
// it takes the terminal raw for the length of one line, with the cursor keys, Home/End,
// Delete, ^A ^E ^B ^F ^K ^U ^W ^D ^L ^C, history (Up/Down, ^P/^N) and Tab completion of
// commands and file names. A kernel with no line discipline gets the old way: poll, echo
// and erase here.
import ulib;

/** A word of a line, or an operator. */
type Tok = { op: str, word: str };
/** One command of a pipeline: its words and its redirections ("" none). */
type Cmd = { args: [str], rin: str, rout: str, rout_app: bool, rerr: str, rerr_app: bool };

let env: [str] = ulib.environ();
let status = 0;
let running = true;
// 2: the kernel edits lines; 1: raw terminal; 0: no line discipline (poll)
let tmode = 0;
let shell_pgid = 0;
let interactive = false;
let exit_status = 0;
let dollar_end = 0;
let syntax_ok = true;
let jobs = 0;

def env_get(name: str) -> str {
    let v = "";
    let pre = name + "=";
    env.foreach((e) => {
        if (len(e) >= len(pre) && e[0:len(pre)] == pre) { v = e[len(pre):len(e)]; };
    });
    v
};

def env_has(name: str) -> bool {
    let has = false;
    let pre = name + "=";
    env.foreach((e) => {
        if (len(e) >= len(pre) && e[0:len(pre)] == pre) { has = true; };
    });
    has
};

def env_unset(name: str) -> void {
    let out: [str] = [];
    let pre = name + "=";
    env.foreach((e) => {
        if (!(len(e) >= len(pre) && e[0:len(pre)] == pre)) { out += e; };
    });
    env = out;
};

def env_set(name: str, value: str) -> void {
    env_unset(name);
    env += name + "=" + value;
};

def is_name_char(c: long, first: bool) -> bool {
    (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || (!first && c >= 48 && c <= 57)
};

/** The value of the $ at line[i]; dollar_end becomes the index after it. */
def dollar(line: str, i: long) -> str {
    let n = len(line);
    dollar_end = i + 1;
    if (i + 1 >= n) { return "$"; };
    let c = line[i + 1];
    if (c == 63) { dollar_end = i + 2; return tostring(status); };
    if (c == 36) { dollar_end = i + 2; return tostring(ulib.getpid()); };
    if (c == 123) {
        let j = i + 2;
        while (j < n && line[j] != 125) { j = j + 1; };
        if (j >= n) { return "$"; };
        dollar_end = j + 1;
        return env_get(line[i + 2:j]);
    };
    if (is_name_char(c, true)) {
        let j = i + 1;
        while (j < n && is_name_char(line[j], false)) { j = j + 1; };
        dollar_end = j;
        return env_get(line[i + 1:j]);
    };
    "$"
};

/** The tokens of `line`; syntax_ok is false when a quote is left open. */
def tokenize(line: str) -> [Tok] {
    let toks: [Tok] = [];
    let n = len(line);
    let i = 0;
    syntax_ok = true;
    while (i < n) {
        let c = line[i];
        if (c == 32 || c == 9 || c == 13 || c == 10) {
            i = i + 1;
        } else if (c == 35) {
            i = n;
        } else if (c == 124 || c == 38 || c == 59 || c == 60 || c == 62 || (c == 50 && i + 1 < n && line[i + 1] == 62)) {
            let op = "";
            if (c == 50) {
                op = "2>";
                i = i + 2;
                if (i < n && line[i] == 62) { op = "2>>"; i = i + 1; };
            } else {
                op = chr(c);
                i = i + 1;
                if ((c == 124 || c == 38 || c == 62) && i < n && line[i] == c) {
                    op = op + chr(c);
                    i = i + 1;
                };
            };
            let t: Tok = { op: op, word: "" };
            toks += t;
        } else {
            // a word: quotes, escapes and expansions glued together
            let w = "";
            let quoted = false;
            let go = true;
            if (c == 126 && (i + 1 >= n || line[i + 1] == 47 || line[i + 1] == 32)) {
                w = env_get("HOME");
                quoted = true;
                i = i + 1;
            };
            while (go && i < n) {
                let d = line[i];
                if (d == 32 || d == 9 || d == 13 || d == 10 || d == 124 || d == 38 || d == 59 || d == 60 || d == 62) {
                    go = false;
                } else if (d == 39) {
                    quoted = true;
                    i = i + 1;
                    while (i < n && line[i] != 39) { w += chr(line[i]); i = i + 1; };
                    if (i >= n) { syntax_ok = false; };
                    i = i + 1;
                } else if (d == 34) {
                    quoted = true;
                    i = i + 1;
                    while (i < n && line[i] != 34) {
                        if (line[i] == 92 && i + 1 < n && (line[i + 1] == 34 || line[i + 1] == 92 || line[i + 1] == 36)) {
                            w += chr(line[i + 1]);
                            i = i + 2;
                        } else if (line[i] == 36) {
                            w += dollar(line, i);
                            i = dollar_end;
                        } else {
                            w += chr(line[i]);
                            i = i + 1;
                        };
                    };
                    if (i >= n) { syntax_ok = false; };
                    i = i + 1;
                } else if (d == 92 && i + 1 < n) {
                    quoted = true;
                    w += chr(line[i + 1]);
                    i = i + 2;
                } else if (d == 36) {
                    w += dollar(line, i);
                    i = dollar_end;
                } else {
                    w += chr(d);
                    i = i + 1;
                };
            };
            if (len(w) > 0 || quoted) {
                let t: Tok = { op: "", word: w };
                toks += t;
            };
        };
    };
    toks
};

/** Can this word be a NAME=value assignment? Its index of the = or -1. */
def assign_at(w: str) -> long {
    if (len(w) == 0 || !is_name_char(w[0], true)) { return -1; };
    let i = 1;
    while (i < len(w) && is_name_char(w[i], false)) { i = i + 1; };
    if (i < len(w) && w[i] == 61) { i } else { -1 }
};

def is_builtin(name: str) -> bool {
    name == "cd" || name == "pwd" || name == "export" || name == "unset" || name == "exit"
        || name == "env" || name == "help" || name == "true" || name == "false" || name == ":" || name == "todesktop"
};

def cwd_now() -> str {
    let d = ulib.getcwd();
    if (d == "") { "/" } else { d }
};

/** Run a builtin; its status. */
def builtin(args: [str]) -> long {
    let name = args[0];
    if (name == "cd") {
        let target = if (len(args) > 1) { args[1] } else { env_get("HOME") };
        if (target == "") { target = "/"; };
        if (ulib.chdir(target) < 0) {
            ulib.write(2, "sh: cd: " + target + ": no such directory\n");
            return 1;
        };
        env_set("PWD", cwd_now());
        return 0;
    };
    if (name == "pwd") { puts(cwd_now() + "\n"); return 0; };
    if (name == "export") {
        let i = 1;
        while (i < len(args)) {
            let at = assign_at(args[i]);
            if (at > 0) { env_set(args[i][0:at], args[i][at + 1:len(args[i])]); };
            i = i + 1;
        };
        return 0;
    };
    if (name == "unset") {
        let i = 1;
        while (i < len(args)) { env_unset(args[i]); i = i + 1; };
        return 0;
    };
    if (name == "exit") {
        exit_status = if (len(args) > 1) { let v = tolong(args[1]); if (v == none) { 2 } else { v! } } else { status };
        running = false;
        return exit_status;
    };
    if (name == "env") { env.foreach((e) => { puts(e + "\n"); }); return 0; };
    if (name == "help") {
        puts("built in: cd pwd export unset exit env help true false NAME=value\n");
        puts("syntax: 'quotes' \"quotes\" $VAR $? ~ | < > >> 2> ; && || &\n");
        puts("programs: ");
        let names = ulib.list_dir("/bin");
        if (!(names == none)) { names!.foreach((n) => { puts(n + " "); }); };
        puts("\n");
        return 0;
    };
    if (name == "false") { return 1; };
    if (name == "todesktop") {
        // show the desktop again: the dock's programs end with it
        let fb = ulib.open("/dev/fb0", 2);
        if (fb < 0) { return 1; };
        syscall(16, fb, 17922, 1);
        ulib.close(fb);
        return 0;
    };
    0
};

/** In a child: wire the redirections of `c` onto fds 0, 1, 2; false on failure. */
def redirect(c: Cmd) -> bool {
    if (c.rin != "") {
        let fd = ulib.open(c.rin, ulib.O_RDONLY);
        if (fd < 0) { ulib.write(2, "sh: " + c.rin + ": cannot open\n"); return false; };
        ulib.dup2(fd, 0);
        ulib.close(fd);
    };
    if (c.rout != "") {
        let fl = ulib.O_WRONLY | ulib.O_CREAT | (if (c.rout_app) { ulib.O_APPEND } else { ulib.O_TRUNC });
        let fd = ulib.open(c.rout, fl);
        if (fd < 0) { ulib.write(2, "sh: " + c.rout + ": cannot create\n"); return false; };
        ulib.dup2(fd, 1);
        ulib.close(fd);
    };
    if (c.rerr != "") {
        let fl = ulib.O_WRONLY | ulib.O_CREAT | (if (c.rerr_app) { ulib.O_APPEND } else { ulib.O_TRUNC });
        let fd = ulib.open(c.rerr, fl);
        if (fd < 0) { ulib.write(2, "sh: " + c.rerr + ": cannot create\n"); return false; };
        ulib.dup2(fd, 2);
        ulib.close(fd);
    };
    true
};

/** In a child: become the program `args[0]`. Never returns. */
def exec_program(args: [str]) -> void {
    let name = args[0];
    if (name.contains("/")) {
        ulib.exec(name, args, env);
    } else {
        let path = env_get("PATH");
        if (path == "") { path = "/bin"; };
        path.split(":").foreach((d) => {
            if (d != "") { ulib.exec(d + "/" + name, args, env); };
        });
        // transitional: the flat Phase-0 image keeps its programs in / (no /bin yet)
        ulib.exec("/" + name, args, env);
    };
    ulib.write(2, "sh: " + name + ": not found\n");
    exit(127);
};

/** Run a pipeline; its status (a background one answers 0 at once). */
def run_pipeline(cmds: [Cmd], bg: bool) -> long {
    let n = len(cmds);
    if (n == 1 && !bg && is_builtin(cmds[0].args[0])) {
        // in this process; its redirections wrap it
        let c = cmds[0];
        let wrapped = c.rin != "" || c.rout != "" || c.rerr != "";
        let s0 = 0;
        let s1 = 0;
        let s2 = 0;
        if (wrapped) { s0 = ulib.dup(0); s1 = ulib.dup(1); s2 = ulib.dup(2); };
        let ok = if (wrapped) { redirect(c) } else { true };
        let r = if (ok) { builtin(c.args) } else { 1 };
        if (wrapped) {
            ulib.dup2(s0, 0);
            ulib.dup2(s1, 1);
            ulib.dup2(s2, 2);
            ulib.close(s0);
            ulib.close(s1);
            ulib.close(s2);
        };
        return r;
    };
    let pids: [long] = [];
    let pg = 0;
    let prev = -1;
    let i = 0;
    while (i < n) {
        let c = cmds[i];
        let p = [-1, -1];
        if (i < n - 1) { p = ulib.pipe(); };
        let pid = ulib.fork();
        if (pid == 0) {
            ulib.setpgid(0, pg);
            if (prev >= 0) { ulib.dup2(prev, 0); ulib.close(prev); };
            if (p[1] >= 0) { ulib.dup2(p[1], 1); ulib.close(p[0]); ulib.close(p[1]); };
            if (!redirect(c)) { exit(1); };
            if (is_builtin(c.args[0])) {
                let r = builtin(c.args);
                exit(r);
            };
            exec_program(c.args);
        };
        if (pid < 0) {
            ulib.write(2, "sh: cannot fork\n");
        } else {
            if (pg == 0) { pg = pid; };
            ulib.setpgid(pid, pg);
            pids += pid;
        };
        if (prev >= 0) { ulib.close(prev); };
        if (p[1] >= 0) { ulib.close(p[1]); };
        prev = p[0];
        i = i + 1;
    };
    if (prev >= 0) { ulib.close(prev); };
    if (len(pids) == 0) { return 1; };
    if (bg) {
        jobs = jobs + 1;
        puts("[" + tostring(jobs) + "]\n");
        return 0;
    };
    if (interactive) { ulib.set_foreground(0, pg); };
    let left = len(pids);
    let last = pids[len(pids) - 1];
    let r = 0;
    let st: [long; 1] = [0; 1];
    while (left > 0) {
        let w = ulib.wait_pid(-1, st, 0);
        if (w < 0) {
            left = 0;
        } else {
            let k = 0;
            while (k < len(pids)) {
                if (pids[k] == w) { left = left - 1; };
                k = k + 1;
            };
            if (w == last) { r = ulib.exit_code(st[0]); };
        };
    };
    if (interactive) { ulib.set_foreground(0, shell_pgid); };
    r
};

/** Build the pipeline of toks[from:to] (no | left): false on a syntax error. */
def run_line(line: str) -> void {
    let toks = tokenize(line);
    if (!syntax_ok) {
        ulib.write(2, "sh: unterminated quote\n");
        status = 2;
        return;
    };
    let i = 0;
    let n = len(toks);
    // the connector that precedes the pipeline being read
    let before = ";";
    while (i < n && running) {
        // one pipeline
        let cmds: [Cmd] = [];
        let args: [str] = [];
        let rin = "";
        let rout = "";
        let rout_app = false;
        let rerr = "";
        let rerr_app = false;
        let sep = "";
        let bad = false;
        let more = true;
        while (more && i < n) {
            let t = toks[i];
            i = i + 1;
            if (t.op == "") {
                args += t.word;
            } else if (t.op == "<" || t.op == ">" || t.op == ">>" || t.op == "2>" || t.op == "2>>") {
                if (i >= n || toks[i].op != "") {
                    bad = true;
                } else {
                    let target = toks[i].word;
                    i = i + 1;
                    if (t.op == "<") { rin = target; }
                    else if (t.op == "2>" || t.op == "2>>") { rerr = target; rerr_app = t.op == "2>>"; }
                    else { rout = target; rout_app = t.op == ">>"; };
                };
            } else {
                if (len(args) == 0 && (t.op == "|" || t.op == "||" || t.op == "&&")) { bad = true; };
                if (t.op == "|") {
                    let c: Cmd = { args: args, rin: rin, rout: rout, rout_app: rout_app, rerr: rerr, rerr_app: rerr_app };
                    if (len(args) == 0) { bad = true; };
                    cmds += c;
                    args = [];
                    rin = "";
                    rout = "";
                    rout_app = false;
                    rerr = "";
                    rerr_app = false;
                } else {
                    sep = t.op;
                    more = false;
                };
            };
        };
        if (len(args) > 0) {
            let c: Cmd = { args: args, rin: rin, rout: rout, rout_app: rout_app, rerr: rerr, rerr_app: rerr_app };
            cmds += c;
        } else if (len(cmds) > 0 || (len(args) == 0 && (rin != "" || rout != "" || rerr != ""))) {
            bad = true;
        };
        if (bad) {
            ulib.write(2, "sh: syntax error\n");
            status = 2;
            return;
        };
        let skip = (before == "&&" && status != 0) || (before == "||" && status == 0);
        if (len(cmds) > 0 && !skip) {
            let first = cmds[0].args;
            let all_assign = len(cmds) == 1;
            first.foreach((w) => { if (assign_at(w) < 0) { all_assign = false; }; });
            if (all_assign) {
                first.foreach((w) => {
                    let at = assign_at(w);
                    env_set(w[0:at], w[at + 1:len(w)]);
                });
                status = 0;
            } else {
                status = run_pipeline(cmds, sep == "&");
            };
        };
        before = if (sep == "&") { ";" } else { sep };
        if (sep == "") { before = ";"; };
    };
};

/** Collect finished background children. */
def reap() -> void {
    let st: [long; 1] = [0; 1];
    let go = true;
    while (go) {
        if (ulib.wait_pid(-1, st, ulib.WNOHANG) <= 0) { go = false; };
    };
};

/** One line from the console without its newline, or none at end of input. */
def read_line() -> str? {
    if (tmode == 2) {
        let b = ulib.read(0, 1024);
        if (len(b) == 0) { return none; };
        let k = len(b);
        while (k > 0 && (b[k - 1] == 10 || b[k - 1] == 13)) { k = k - 1; };
        return some(from_bytes(b[0:k]));
    };
    let line = "";
    let done = false;
    while (!done) {
        let b = ulib.read(0, 1);
        if (len(b) == 0) {
            // nothing typed yet: poll again
        } else {
            let c = b[0];
            if (c == 10 || c == 13) {
                puts("\n");
                done = true;
            } else if (c == 127 || c == 8) {
                if (len(line) > 0) {
                    line = line[0:len(line) - 1];
                    puts(chr(8) + " " + chr(8));
                };
            } else if (c == 4 && len(line) == 0) {
                puts("exit\n");
                return none;
            } else if (c >= 32 && c < 127) {
                line += chr(c);
                puts(chr(c));
            };
        };
    };
    some(line)
};

// ── line editing ────────────────────────────────────────────────────────

let hist: [str] = [];
let ed_buf = "";
let ed_pos = 0;

def has_prefix(s: str, pre: str) -> bool { len(s) >= len(pre) && s[0:len(pre)] == pre };

def common_prefix(a: str, b: str) -> str {
    let i = 0;
    while (i < len(a) && i < len(b) && a[i] == b[i]) { i = i + 1; };
    a[0:i]
};

/** Redraw the prompt and the line, and put the cursor back at ed_pos. */
def ed_refresh(pr: str) -> void {
    let back = len(ed_buf) - ed_pos;
    let tail = "";
    if (back > 0) { tail = chr(27) + "[" + tostring(back) + "D"; };
    puts("\r" + pr + ed_buf + chr(27) + "[K" + tail);
};

def ed_set(line: str, pr: str) -> void {
    ed_buf = line;
    ed_pos = len(line);
    ed_refresh(pr);
};

/** The names a word can complete to: commands for the first word of a command, else entries of its directory (directories end in /). */
def candidates(w: str, first: bool) -> [str] {
    let out: [str] = [];
    let slash = -1;
    let i = 0;
    while (i < len(w)) {
        if (w[i] == 47) { slash = i; };
        i = i + 1;
    };
    if (first && slash < 0) {
        ["cd", "pwd", "export", "unset", "exit", "env", "help", "true", "false", "todesktop"].foreach((b) => {
            if (has_prefix(b, w)) { out += b; };
        });
        let path = env_get("PATH");
        if (path == "") { path = "/bin"; };
        path.split(":").foreach((d) => {
            if (d != "") {
                let ents = ulib.read_dir(d);
                if (!(ents == none)) {
                    ents!.foreach((e) => {
                        if (e.kind != 4 && has_prefix(e.name, w)) { out += e.name; };
                    });
                };
            };
        });
    } else {
        let dir = ".";
        if (slash == 0) { dir = "/"; } else if (slash > 0) { dir = w[0:slash]; };
        let base = w[slash + 1:len(w)];
        let ents = ulib.read_dir(dir);
        if (!(ents == none)) {
            ents!.foreach((e) => {
                let hide = len(e.name) > 0 && e.name[0] == 46 && !(len(base) > 0 && base[0] == 46);
                if (e.name != "." && e.name != ".." && !hide && has_prefix(e.name, base)) {
                    let full = if (dir == "/") { "/" + e.name } else { dir + "/" + e.name };
                    if (e.kind == 4 || (e.kind == 0 && ulib.is_dir(full))) { out += e.name + "/"; } else { out += e.name; };
                };
            });
        };
    };
    // sorted, without repeats
    let k = 1;
    while (k < len(out)) {
        let j = k;
        while (j > 0 && out[j - 1] > out[j]) {
            let t = out[j];
            out[j] = out[j - 1];
            out[j - 1] = t;
            j = j - 1;
        };
        k = k + 1;
    };
    let uniq: [str] = [];
    out.foreach((n) => { if (len(uniq) == 0 || uniq[len(uniq) - 1] != n) { uniq += n; }; });
    uniq
};

/** Insert `s` at the cursor. */
def ed_insert(s: str, pr: str) -> void {
    if (ed_pos == len(ed_buf)) {
        ed_buf += s;
        ed_pos = len(ed_buf);
        puts(s);
    } else {
        ed_buf = ed_buf[0:ed_pos] + s + ed_buf[ed_pos:len(ed_buf)];
        ed_pos = ed_pos + len(s);
        ed_refresh(pr);
    };
};

/** Tab: complete the word before the cursor; a second Tab on an ambiguous word lists the choices. */
def ed_complete(pr: str, again: bool) -> bool {
    let ws = ed_pos;
    while (ws > 0 && !(ed_buf[ws - 1] == 32 || ed_buf[ws - 1] == 9 || ed_buf[ws - 1] == 124 || ed_buf[ws - 1] == 59
        || ed_buf[ws - 1] == 38 || ed_buf[ws - 1] == 60 || ed_buf[ws - 1] == 62)) { ws = ws - 1; };
    let w = ed_buf[ws:ed_pos];
    let k = 0;
    while (k < len(w)) {
        if (w[k] == 39 || w[k] == 34 || w[k] == 92 || w[k] == 36) { return false; };
        k = k + 1;
    };
    // the first word of a command: nothing before it but blanks, or a connector
    let b = ws;
    while (b > 0 && (ed_buf[b - 1] == 32 || ed_buf[b - 1] == 9)) { b = b - 1; };
    let first = b == 0 || ed_buf[b - 1] == 124 || ed_buf[b - 1] == 59 || ed_buf[b - 1] == 38;
    let cs = candidates(w, first);
    if (len(cs) == 0) { return false; };
    let slash = -1;
    let i = 0;
    while (i < len(w)) {
        if (w[i] == 47) { slash = i; };
        i = i + 1;
    };
    let base = w[slash + 1:len(w)];
    let common = cs[0];
    cs.foreach((c) => { common = common_prefix(common, c); });
    let add = common[len(base):len(common)];
    let esc = "";
    let j = 0;
    while (j < len(add)) {
        if (add[j] == 32) { esc += "\\"; };
        esc += chr(add[j]);
        j = j + 1;
    };
    if (len(cs) == 1 && !(len(cs[0]) > 0 && cs[0][len(cs[0]) - 1] == 47)) { esc += " "; };
    if (esc != "") {
        ed_insert(esc, pr);
        return true;
    };
    if (len(cs) > 1 && again) {
        puts("\n");
        let width = 0;
        cs.foreach((c) => { if (len(c) > width) { width = len(c); }; });
        width = width + 2;
        let per = 78 / width;
        if (per < 1) { per = 1; };
        let n = 0;
        cs.foreach((c) => {
            puts(c);
            n = n + 1;
            if (n % per == 0) { puts("\n"); } else { puts(" ".repeat(width - len(c))); };
        });
        if (n % per != 0) { puts("\n"); };
        ed_refresh(pr);
    };
    true
};

/** One line, edited here: the prompt is printed, the terminal is raw until the line is done. */
def edit_line() -> str? {
    let pr = prompt();
    let saved = ulib.tty_get(0);
    let rawt = ulib.tty_get(0);
    if (len(saved) == 0 || len(rawt) == 0) {
        puts(pr);
        return read_line();
    };
    // no ISIG ICANON ECHO* IEXTEN; one byte at a time, no timer
    let lf = ulib.le(rawt, 12, 4) & ~(1 | 2 | 8 | 16 | 32 | 64 | 512 | 2048 | 32768);
    rawt[12] = lf & 255;
    rawt[13] = (lf >> 8) & 255;
    rawt[14] = (lf >> 16) & 255;
    rawt[15] = (lf >> 24) & 255;
    rawt[17 + 5] = 0;
    rawt[17 + 6] = 1;
    ulib.tty_set(0, rawt);
    puts(pr);
    ed_buf = "";
    ed_pos = 0;
    let hidx = len(hist);
    let draft = "";
    let result: str? = none;
    let done = false;
    let tabs = 0;
    while (!done) {
        let b = ulib.read(0, 1);
        if (len(b) == 0) {
            done = true;
        } else {
            let c = b[0];
            let was_tab = false;
            if (c == 10 || c == 13) {
                puts("\n");
                result = some(ed_buf);
                done = true;
            } else if (c == 9) {
                ed_complete(pr, tabs > 0);
                was_tab = true;
            } else if (c == 127 || c == 8) {
                if (ed_pos > 0) {
                    if (ed_pos == len(ed_buf)) {
                        ed_buf = ed_buf[0:ed_pos - 1];
                        ed_pos = ed_pos - 1;
                        puts(chr(8) + " " + chr(8));
                    } else {
                        ed_buf = ed_buf[0:ed_pos - 1] + ed_buf[ed_pos:len(ed_buf)];
                        ed_pos = ed_pos - 1;
                        ed_refresh(pr);
                    };
                };
            } else if (c == 4) {
                if (len(ed_buf) == 0) {
                    puts("exit\n");
                    done = true;
                } else if (ed_pos < len(ed_buf)) {
                    ed_buf = ed_buf[0:ed_pos] + ed_buf[ed_pos + 1:len(ed_buf)];
                    ed_refresh(pr);
                };
            } else if (c == 3) {
                puts("^C\n");
                result = some("");
                done = true;
            } else if (c == 1) {
                ed_pos = 0;
                ed_refresh(pr);
            } else if (c == 5) {
                ed_pos = len(ed_buf);
                ed_refresh(pr);
            } else if (c == 2) {
                if (ed_pos > 0) { ed_pos = ed_pos - 1; ed_refresh(pr); };
            } else if (c == 6) {
                if (ed_pos < len(ed_buf)) { ed_pos = ed_pos + 1; ed_refresh(pr); };
            } else if (c == 11) {
                ed_buf = ed_buf[0:ed_pos];
                ed_refresh(pr);
            } else if (c == 21) {
                ed_buf = ed_buf[ed_pos:len(ed_buf)];
                ed_pos = 0;
                ed_refresh(pr);
            } else if (c == 23) {
                let e = ed_pos;
                while (e > 0 && ed_buf[e - 1] == 32) { e = e - 1; };
                while (e > 0 && ed_buf[e - 1] != 32) { e = e - 1; };
                ed_buf = ed_buf[0:e] + ed_buf[ed_pos:len(ed_buf)];
                ed_pos = e;
                ed_refresh(pr);
            } else if (c == 12) {
                puts(chr(27) + "[H" + chr(27) + "[2J");
                ed_refresh(pr);
            } else if (c == 16 || c == 14) {
                // ^P, ^N: as Up, Down
                c = if (c == 16) { 65 } else { 66 };
                if (c == 65 && hidx > 0) {
                    if (hidx == len(hist)) { draft = ed_buf; };
                    hidx = hidx - 1;
                    ed_set(hist[hidx], pr);
                } else if (c == 66 && hidx < len(hist)) {
                    hidx = hidx + 1;
                    ed_set(if (hidx == len(hist)) { draft } else { hist[hidx] }, pr);
                };
            } else if (c == 27) {
                let b2 = ulib.read(0, 1);
                let key = 0;
                let param = 0;
                if (len(b2) > 0 && (b2[0] == 91 || b2[0] == 79)) {
                    let more = true;
                    while (more) {
                        let b3 = ulib.read(0, 1);
                        if (len(b3) == 0) {
                            more = false;
                        } else if (b3[0] >= 48 && b3[0] <= 57) {
                            param = param * 10 + b3[0] - 48;
                        } else if (b3[0] == 59) {
                            param = 0;
                        } else {
                            key = b3[0];
                            more = false;
                        };
                    };
                };
                if (key == 65 && hidx > 0) {
                    if (hidx == len(hist)) { draft = ed_buf; };
                    hidx = hidx - 1;
                    ed_set(hist[hidx], pr);
                } else if (key == 66 && hidx < len(hist)) {
                    hidx = hidx + 1;
                    ed_set(if (hidx == len(hist)) { draft } else { hist[hidx] }, pr);
                } else if (key == 67) {
                    if (ed_pos < len(ed_buf)) { ed_pos = ed_pos + 1; ed_refresh(pr); };
                } else if (key == 68) {
                    if (ed_pos > 0) { ed_pos = ed_pos - 1; ed_refresh(pr); };
                } else if (key == 72 || (key == 126 && (param == 1 || param == 7))) {
                    ed_pos = 0;
                    ed_refresh(pr);
                } else if (key == 70 || (key == 126 && (param == 4 || param == 8))) {
                    ed_pos = len(ed_buf);
                    ed_refresh(pr);
                } else if (key == 126 && param == 3) {
                    if (ed_pos < len(ed_buf)) {
                        ed_buf = ed_buf[0:ed_pos] + ed_buf[ed_pos + 1:len(ed_buf)];
                        ed_refresh(pr);
                    };
                };
            } else if (c >= 32) {
                ed_insert(from_bytes([c]), pr);
            };
            if (was_tab) { tabs = tabs + 1; } else { tabs = 0; };
        };
    };
    ulib.tty_set(0, saved);
    if (!(result == none) && result! != "" && (len(hist) == 0 || hist[len(hist) - 1] != result!)) {
        hist += result!;
        if (len(hist) > 200) { hist = hist[len(hist) - 200:len(hist)]; };
    };
    result
};

def prompt() -> str {
    let u = env_get("USER");
    if (u == "") { u = "user"; };
    u + ":" + cwd_now() + "$ "
};

let a = argv();
if (len(a) >= 3 && a[1] == "-c") {
    run_line(a[2]);
    exit(status);
} else if (len(a) >= 2) {
    let d = ulib.read_all(a[1]);
    if (d == none) {
        ulib.write(2, "sh: " + a[1] + ": cannot open\n");
        exit(127);
    };
    from_bytes(d!).split("\n").foreach((l) => { if (running) { run_line(l); }; });
    exit(if (running) { status } else { exit_status });
};
tmode = ulib.tty_mode(0);
interactive = tmode == 2;
if (interactive) {
    shell_pgid = ulib.getpgid(0);
    if (shell_pgid <= 0) { shell_pgid = ulib.getpid(); };
};
if (env_get("PWD") == "") { env_set("PWD", cwd_now()); };
while (running) {
    reap();
    let l: str? = none;
    if (interactive) { l = edit_line(); } else { puts(prompt()); l = read_line(); };
    if (l == none) {
        running = false;
    } else {
        run_line(l!);
    };
};
exit(exit_status);
