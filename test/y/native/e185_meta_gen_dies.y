// expect-error: e185_meta_gen_dies.y:10
// expect-error: and the first block that produced nothing was at
// The generator runs in a forked child, so a trap in it is a diagnostic
// naming the block, not a trap in ycc: ycc's own exit status survives, and the
// child's own message is on stdout, which is the child's fd 1.
def boom() -> str {
    let b = [1];
    return tostring(b[7]);
};
let x = #{ boom() }#;
print(x);
