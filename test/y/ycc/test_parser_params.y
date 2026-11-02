import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";
import tags from "../../../src/y/tags.y";

let src = "def f(a: long) { a };";
print("tokenizing...");
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
print("parsing...");
let ast = parser.parse_program(toks);
print("parsed, kind = " + ast.k);
print("stmts = " + tostring(len(ast.stmts)));

// Parameter type inference is a post-parse phase now. These checks are at the
// tree level: the parser's result must already have the inferred ptypes.
def first_func(src: str) -> Func {
    let a = parser.parse_program(lexer.tokenize(src));
    let stmts = a.stmts;
    let d: Decl = stmts[0];
    let f: Func = d.v;
    f
};

let body = first_func("def f(a) -> long { a + 1 };");
if (body.ptypes[0].k != K.tlong) {
    print("FAIL: body hint did not infer long");
    exit(1);
};
let call = first_func("def f(a) -> long { a }; print(f(2));");
if (call.ptypes[0].k != K.tlong) {
    print("FAIL: call-site hint did not infer long");
    exit(1);
};
let annotated = first_func("def f(a: byte) -> long { a };");
if (annotated.ptypes[0].k != K.tbyte) {
    print("FAIL: an annotation was overwritten");
    exit(1);
};

// A `=>` arrow is typed by its call context, not by body hints; that is the
// pre-separation behaviour, and the difference shows up in code generation.
let aa = parser.parse_program(lexer.tokenize("let f = x => x + 1;"));
let astmts = aa.stmts;
let ad: Decl = astmts[0];
let af: Func = ad.v;
if (!af.arrow || af.ptypes[0].k != K.tnone) {
    print("FAIL: an arrow's parameter should stay untyped at parse");
    exit(1);
};
print("PARAM INFERENCE CHECKS PASSED");
