// A global nothing READS does not need its initializer, and for a table that
// is a whole range of instructions: the hundreds of pushes and stores that
// build it at startup. The emitter brackets each global's initializer with
// `ygiS_<cell>` / `ygiE_<cell>` marks and the link step deletes the range for
// a dead cell (TODO.md 9), which is what an unused `import math;` costs --
// 6705 bytes of const tables built and read by nobody.
//
// The three tables below are never named again: dead, so their initializers
// go. USED is read, so its initializer stays and the answer is the same
// either way. The point of the fixture is that answer.
const USED: [long; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
const DEAD_A: [long; 8] = [10, 20, 30, 40, 50, 60, 70, 80];
const DEAD_B: [long; 128] = [7; 128];
const DEAD_C: [long; 4] = [9, 9, 9, 9];
def main() -> long {
    let total = 0;
    let i = 0;
    while (i < 8) { total += USED[i]; i = i + 1; };
    print(total);
    0
};
exit(main());
