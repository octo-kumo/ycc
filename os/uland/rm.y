// rm [-r] [-f] path... -- remove files; -r removes directories and what is in them.
import ulib;

def join_path(dir: str, name: str) -> str {
    if (dir[len(dir) - 1] == 47) { dir + name } else { dir + "/" + name }
};

/** Remove `path` and, for a directory, everything under it. */
def remove_tree(path: str) -> long {
    if (!ulib.is_dir(path)) { return ulib.unlink(path); };
    let ents = ulib.read_dir(path);
    let r = 0;
    if (!(ents == none)) {
        ents!.foreach((e) => {
            if (e.name != "." && e.name != "..") {
                if (remove_tree(join_path(path, e.name)) < 0) { r = -1; };
            };
        });
    };
    if (ulib.rmdir(path) < 0) { r = -1; };
    r
};

let a = argv();
let rec = false;
let force = false;
let bad = 0;
let n = 0;
let i = 1;
while (i < len(a)) {
    if (len(a[i]) > 1 && a[i][0] == 45) {
        let k = 1;
        while (k < len(a[i])) {
            if (a[i][k] == 114 || a[i][k] == 82) { rec = true; };
            if (a[i][k] == 102) { force = true; };
            k = k + 1;
        };
    } else {
        n = n + 1;
        if (rec) {
            if (!ulib.exists(a[i]) && !ulib.is_dir(a[i])) {
                if (!force) { puts("rm: " + a[i] + ": no such file\n"); bad = 1; };
            } else if (remove_tree(a[i]) < 0) {
                puts("rm: cannot remove " + a[i] + "\n");
                bad = 1;
            };
        } else if (ulib.unlink(a[i]) < 0) {
            if (ulib.is_dir(a[i])) {
                puts("rm: " + a[i] + ": is a directory (use -r)\n");
                bad = 1;
            } else if (!force) {
                puts("rm: " + a[i] + ": no such file\n");
                bad = 1;
            };
        };
    };
    i = i + 1;
};
if (n == 0 && !force) { puts("usage: rm [-r] [-f] <path>...\n"); exit(1); };
exit(bad);
