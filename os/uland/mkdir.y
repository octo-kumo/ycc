// mkdir [-p] dir... -- make directories; -p makes the parents too and accepts one that exists.
import ulib;
let a = argv();
let parents = false;
let bad = 0;
let n = 0;
let i = 1;
while (i < len(a)) {
    if (a[i] == "-p") {
        parents = true;
    } else {
        n = n + 1;
        let path = a[i];
        if (parents) {
            // every prefix in turn: a/b/c makes a, a/b, a/b/c
            let k = 1;
            while (k <= len(path)) {
                if (k == len(path) || path[k] == 47) {
                    let pre = path[0:k];
                    if (!ulib.is_dir(pre)) { ulib.mkdir(pre); };
                };
                k = k + 1;
            };
            if (!ulib.is_dir(path)) { puts("mkdir: cannot create " + path + "\n"); bad = 1; };
        } else if (ulib.mkdir(path) < 0) {
            puts("mkdir: cannot create " + path + "\n");
            bad = 1;
        };
    };
    i = i + 1;
};
if (n == 0) { puts("usage: mkdir [-p] <dir>...\n"); exit(1); };
exit(bad);
