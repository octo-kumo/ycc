// echo: print the arguments joined by spaces.  Nothing from the kernel -- which is the
// point of the trivial commands: they are PROGRAMS built from syscalls that are already
// pinned from ring 3, and they need no new plumbing at all.
let a = argv();
let out = "";
let i = 1;
while (i < len(a)) {
    out += a[i];
    if (i + 1 < len(a)) { out += " "; };
    i = i + 1;
};
print(out + "\n");
