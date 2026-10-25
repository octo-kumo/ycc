// Imported files share one namespace, but only a top-level def that
// replaces another file's is an error (e132). All of these are fine:
// replacing a std def, in the program or in a module (the compiler's own
// chunks are not the user's files); a nested def named like another
// file's; the same module imported twice (it is spliced once); and
// top-level lets of the same name, which resolve lexically.
import m from "m134/m.y";
import again from "m134/m.y";

def readline() -> str? { some("mine") };
def other(x: long) -> long {
    def lf(y: long) -> long { y * 10 };
    lf(x)
};
let count = 99;
print(readline()!);
print(m.eof_state());
print(again.lf(1) + other(2));
print(m.get());
print(count);
