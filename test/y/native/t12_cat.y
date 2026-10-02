// A pure-Y cat over std/fs.y's fds: 0 is stdin, 1 stdout.
import fs;
let go = true;
while (go) {
    let b = fs.read_some(0, 512);
    if (len(b) == 0) { go = false; } else { fs.write_data(1, b); };
};
