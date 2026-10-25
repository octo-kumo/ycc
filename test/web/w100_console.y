// W5 browser console: stdout, stdin from ?stdin=, and a stderr line.
import fs;
puts("out before\n");
region {
    let b = fs.read_some(0, 256);
    if (b.length > 0) { puts(from_bytes(b)); };
};
eputs("stderr line\n");
