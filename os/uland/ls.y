// ls [-l] [-a] [path...] -- list directories (the working directory by default) or files.
// -l: mode, size and name; -a: also the names that start with a dot.
import ulib;

/** The `drwxr-xr-x` form of a mode. */
def mode_str(mode: long) -> str {
    let kind = mode & ulib.S_IFMT;
    let t = if (kind == ulib.S_IFDIR) { "d" } else if (kind == 8192) { "c" } else if (kind == 49152) { "s" } else { "-" };
    let bits = "rwxrwxrwx";
    let out = t;
    let i = 0;
    while (i < 9) {
        out += if ((mode & (256 >> i)) != 0) { bits[i:i + 1] } else { "-" };
        i = i + 1;
    };
    out
};

def pad_left(s: str, w: long) -> str {
    let out = s;
    while (len(out) < w) { out = " " + out; };
    out
};

/** One line for `name` (found at `path`). */
def show(path: str, name: str, long_form: bool) -> void {
    if (long_form) {
        let s = ulib.stat(path);
        if (s == none) {
            puts("?????????? " + pad_left("?", 8) + " " + name + "\n");
        } else {
            puts(mode_str(s!.mode) + " " + pad_left(tostring(s!.size), 8) + " " + name + "\n");
        };
    } else {
        puts(name + "\n");
    };
};

def sorted(names: [str]) -> [str] {
    let a = names;
    let i = 1;
    while (i < len(a)) {
        let x = a[i];
        let j = i - 1;
        while (j >= 0 && a[j] > x) { a[j + 1] = a[j]; j = j - 1; };
        a[j + 1] = x;
        i = i + 1;
    };
    a
};

def join_path(dir: str, name: str) -> str {
    if (dir[len(dir) - 1] == 47) { dir + name } else { dir + "/" + name }
};

let a = argv();
let long_form = false;
let all = false;
let paths: [str] = [];
let i = 1;
while (i < len(a)) {
    if (len(a[i]) > 1 && a[i][0] == 45) {
        let k = 1;
        while (k < len(a[i])) {
            if (a[i][k] == 108) { long_form = true; };
            if (a[i][k] == 97) { all = true; };
            k = k + 1;
        };
    } else { paths += a[i]; };
    i = i + 1;
};
// (a kernel with no "." has one directory, the root)
if (len(paths) == 0) { paths += if (ulib.exists(".") || !(ulib.read_dir(".") == none)) { "." } else { "/" }; };
let bad = 0;
paths.foreach((p) => {
    let s = ulib.stat(p);
    // a kernel that cannot stat may still list: a path that opens as a directory is one
    let lst = if (s == none) { ulib.read_dir(p) } else { none };
    if (s == none && lst == none) {
        puts("ls: " + p + ": no such file or directory\n");
        bad = 1;
    } else if (!(s == none) && (s!.mode & ulib.S_IFMT) != ulib.S_IFDIR) {
        show(p, p, long_form);
    } else {
        let ents = if (lst == none) { ulib.read_dir(p) } else { lst };
        if (len(paths) > 1) { puts(p + ":\n"); };
        let names: [str] = [];
        ents!.foreach((e) => {
            if (all || e.name[0] != 46) { names += e.name; };
        });
        sorted(names).foreach((n) => { show(join_path(p, n), n, long_form); });
    };
});
exit(bad);
