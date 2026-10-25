// W4/S8: a stack overflow.  The Y stack is linear memory below DATA_LO, so
// recursing past it is a wasm out-of-bounds access, which the host reports as
// a segmentation fault and status 139 -- the same status a native build's
// SIGSEGV gives.  (The recursion is not tail: every frame is live.)
def deep(n: long) -> long {
    if (n == 0) { 0 } else { 1 + deep(n - 1) }
};
print("start\n");
print(deep(10000000), "\n");
