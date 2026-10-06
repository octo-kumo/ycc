// `fs.list_dir` reads into one buffer the module owns (SUGGESTIONS.md 22: a
// per-call 32 KiB cost 43 592 B of arena a call, 6.56 MB a walk over a
// 201-directory tree). The property that makes that safe is here: the answer
// does not depend on what the PREVIOUS call left in the buffer, and calling it
// twice gives the same list -- the second call reuses a dirty buffer, which is
// exactly where a missing reset would show.
import fs;
let a = fs.list_dir(".");
let b = fs.list_dir(".");
let same = a == b;
print(same);
let c = fs.list_dir(".");
print(a == c);
// A directory that does not exist is none: no stale names leak out of the
// shared buffer that way either. (No path that depends on the working
// directory: this fixture runs under both targets, wine included.)
print(fs.list_dir("no such directory here") == none);
let d = fs.list_dir(".");
print(d != none);
