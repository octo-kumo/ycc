// sh -- the Y-OS shell: read a line from the console, run it.
//
// The console never reports end of file: a read that finds no byte returns 0,
// so the line editor polls. It also does the echo and the erase (the terminal
// is raw: nothing is shown unless a program shows it).
//
// A command is split on spaces. A few words are built in; anything else is a
// program in the root directory ("ls" runs /ls), started with fork + execve and
// waited for with wait4. There is no quoting, no redirection and no pipe yet.
import ulib;

/** One edited line from the console, without its newline. */
def read_line() -> str {
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
                    puts("\b \b");
                };
            } else if (c == 4 && len(line) == 0) {
                // ctrl-D on an empty line: leave
                puts("exit\n");
                line = "exit";
                done = true;
            } else if (c >= 32 && c < 127) {
                line += chr(c);
                puts(chr(c));
            };
        };
    };
    line
};

/** The words of `line`. */
def words(line: str) -> [str] {
    let out: [str] = [];
    let cur = "";
    let i = 0;
    while (i < len(line)) {
        if (line[i] == 32 || line[i] == 9) {
            if (len(cur) > 0) { out += cur; cur = ""; };
        } else {
            cur += chr(line[i]);
        };
        i = i + 1;
    };
    if (len(cur) > 0) { out += cur; };
    out
};

def help() -> void {
    puts("built in: help, exit (or halt)\n");
    puts("programs: ");
    let names = ulib.list_dir("/");
    if (!(names == none)) {
        names!.foreach((n) => { puts(n + " "); });
    };
    puts("\n");
};

/** Run `w` as a program and wait for it. */
def run(w: [str]) -> void {
    let path = w[0];
    if (path[0] != 47) { path = "/" + path; };
    let pid = ulib.fork();
    if (pid == 0) {
        ulib.exec(path, w);
        puts("sh: " + w[0] + ": not found\n");
        exit(127);
    } else if (pid < 0) {
        puts("sh: cannot fork\n");
    } else {
        ulib.wait_child();
    };
};

puts("Y-OS shell. Type help.\n");
let running = true;
while (running) {
    puts("$ ");
    let w = words(read_line());
    if (len(w) == 0) {
        // empty line
    } else if (w[0] == "exit" || w[0] == "halt") {
        running = false;
    } else if (w[0] == "help") {
        help();
    } else {
        run(w);
    };
};
puts("bye\n");
ulib.halt();
