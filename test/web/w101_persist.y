// W5 persistence: write or read /home/web/persist.txt across page runs.
import fs;
let p = "/home/web/persist.txt";
let mode = "write";
if (argv().length > 1) { mode = argv()[1]; };
if (mode == "write") {
    let ok = fs.write_file(p, "persisted\n");
    puts("write " + tostring(ok) + "\n");
} else {
    region {
        let t = fs.read_file(p);
        if (t == none) { puts("missing\n"); } else { puts(unwrap(t)); };
    };
};
