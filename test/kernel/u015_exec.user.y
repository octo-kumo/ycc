// execve: print a marker, then replace this process with /prog -- itself.  If
// execve works the program starts again and prints the marker again, forever; if it
// does not, the syscall returns and the second line appears instead.  The fixture's
// expected is the first TWO markers, so a program that never gets replaced cannot
// match it.
print("marker\n");
let p: [byte] = [];
let s = "/prog";
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let r = syscall(59, ptr_addr(&p[0]), 0, 0);
print("execve returned " + tostring(r) + "\n");
