// child -- what b1 exec starts: prints its argv, finds its environment on the
// stack, and writes to the descriptors named in argv[1] (inherited) and argv[2] (close-on-exec).
import b1 from "./b1.y";

/** The text of the NUL-terminated string at address a. */
def cstr_at(a: long) -> str {
    let p: *byte = ptr_from(a);
    let out = "";
    let i = 0;
    while (*(p + i) != 0 && i < 200) { out += chr(*(p + i)); i = i + 1; };
    out
};

def run_child() -> void {
let av = argv();
puts("argc " + tostring(len(av)) + "\n");
let i = 0;
while (i < len(av)) { puts("argv " + tostring(i) + " " + av[i] + "\n"); i = i + 1; };

// the environment: scan the stack words above a local for pointers to NAME=value
def local_addr() -> long { let probe = 0; ptr_addr(&probe) };
let base = local_addr();
let wp: *long = ptr_from(base);
let k = 0;
let found = 0;
while (base + k * 8 < 100663296 + 4096 - 16) {
    let w = *(wp + k);
    if (w > base && w < 100663296 + 4096) {
        let s = cstr_at(w);
        if (len(s) > 6 && s[0:6] == "B1KEY=") { found += 1; puts("env " + s + "\n"); };
        if (len(s) > 4 && s[0:4] == "B1B=") { found += 1; puts("env " + s + "\n"); };
    };
    k = k + 1;
};
puts("env entries " + tostring(found) + "\n");

if (len(av) >= 4) {
    let a = av[2];
    let b = av[3];
    let fa = 0;
    let fb = 0;
    let j = 0;
    while (j < len(a)) { fa = fa * 10 + a[j] - 48; j = j + 1; };
    j = 0;
    while (j < len(b)) { fb = fb * 10 + b[j] - 48; j = j + 1; };
    b1.wr(fa, "from-child");
    b1.check("cloexec fd is closed", b1.wr(fb, "no") < 0);
};
exit(9);
};
