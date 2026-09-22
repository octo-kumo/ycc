// Test driver: run Y source through ycc's lexer -> parser -> Y VM.
// NOTE: ycc only supports double-quoted strings, so inner quotes are escaped.
import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";
import vm from "./vm.y";

// Builtins the VM exposes to user programs (native Y functions, passed by ref).
let builtin_names = ["print", "len", "substr", "push", "tostring", "typeof", "range", "index_of", "arr_index_of", "ord", "chr", "join", "split", "trim", "tonum", "puts", "map_set", "map_get", "last_index_of", "scope_new", "scope_def", "scope_find", "scope_get", "scope_set"];
let builtin_vals = [print, len, substr, push, tostring, typeof, range, index_of, arr_index_of, ord, chr, join, split, trim, tonum, puts, map_set, map_get, last_index_of, scope_new, scope_def, scope_find, scope_get, scope_set];

def run(src: str) -> null {
    let toks = lexer.tokenize(src);
    let ast = parser.parse_program(toks);
    vm.vm_run(ast, builtin_names, builtin_vals);
    null
};

// ── tests ────────────────────────────────────────────────────────────────
run("print(\"hello from the Y VM\");");
run("print(1 + 2 * 3);");
run("def fib(n: long) -> long { if (n < 2) { n } else { self(n-1) + self(n-2) } }; print(fib(10));");
run("let s = 0; foreach (x in [1,2,3,4]) { s = s + x; }; print(s);");
run("let t = 0; for i in 0..5 { t = t + i; }; print(t);");
run("def make(n: long) -> (long) -> long { def add(x: long) -> long { x + n }; add }; let f = make(10); print(f(5));");
run("let m = { a: 1, b: 2 }; print(m.a + m.b);");
run("let arr = [10, 20, 30, 40]; print(arr[1:3]); print(len(arr));");
