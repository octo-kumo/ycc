// test_check.y — exercise the LSP checker on good and bad programs.
import check from "./check.y";

def show(label: str, src: str) {
    print("── " + label + " ──");
    let diags = check.check(src);
    if (len(diags) == 0) {
        print("  (no diagnostics)");
    } else {
        foreach (d in diags) {
            print("  " + d.severity + " @" + tostring(d.line) + ":" + tostring(d.col) + " " + d.message);
        };
    };
};

show("clean program", "let x = 1;\nlet y = x + 2;\nprint(y);");

show("undefined variable", "let x = 1;\nprint(y);");

show("undefined in assign", "x = 5;");

show("scoped OK", "def f(a: long) -> long { a + 1 };\nprint(f(2));");

show("undefined param body", "def f(a: long) -> long { b + 1 };");

show("foreach binding", "foreach (i in [1,2,3]) { print(i); };");

show("undefined in loop", "foreach (i in [1,2,3]) { print(j); };");

show("nested scope leak", "{ let inner = 1; };\nprint(inner);");
