// expect-error: m132/b.y:4:1: error: duplicate definition 'helper': m132/a.y:5 defines it too (imported files share one namespace; rename one)
// expect-error: 12:1: error: duplicate definition 'twice': m132/a.y:7 defines it too (imported files share one namespace; rename one)
// Imported files share one namespace, where a later def replaces an
// earlier one: a.fa() would quietly call b.y's helper, and a.twice the
// program's. Within one file that is deliberate (t30's dup); across files
// it is an error, at the later def, naming the other.
import a from "m132/a.y";
import b from "m132/b.y";

print(a.fa() + b.fb());
print(a.twice(2));
def twice(x: long) -> long { x * 3 };
