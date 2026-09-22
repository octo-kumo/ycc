import io from "../../../src/y/std/io.y";
let buf = [0; 64];
let go = true;
while (go) {
    let n = io.read(0, &buf, 512);
    if (n <= 0) { go = false; } else { io.write(1, &buf, n); go = true; };
};
