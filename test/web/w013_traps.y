// W4/S8: an out-of-bounds index stops through the runtime's y_oob, which
// names what happened and exits 1 -- the same message and status as the
// native build.  (ud2 and int3 lower to trap(4)/trap(5) and status 132/133,
// but Y has no way to write one; see w013b_stack_overflow for a real wasm
// trap.)
let a = [1, 2, 3];
let i = 0;
while (i < 3) { print(a[i], " "); i = i + 1; };
print("\n");
print(a[5], "\n");
print("not reached\n");
