// Three files defining one name, which find_dup finds by walking a name's own
// definitions backwards: each later file must be told about the file before it,
// not the first one (m134/b.y against m134/a.y, m134/c.y against m134/b.y).
// With one scan over every earlier statement per name -- quadratic in the
// program's definitions -- that "the one before it" was the last match the scan
// happened to leave in `other`; with a chain per name it is the first entry
// found walking back, which is the same answer for a different reason.
// expect-error: m134/b.y:4:1: error: duplicate definition 'helper': m134/a.y:4 defines it too (imported files share one namespace; rename one)
// expect-error: m134/c.y:4:1: error: duplicate definition 'helper': m134/b.y:4 defines it too (imported files share one namespace; rename one)
import a from "m134/a.y";
import b from "m134/b.y";
import c from "m134/c.y";

print(a.fa() + b.fb() + c.fc());
