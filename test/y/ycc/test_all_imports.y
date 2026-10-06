// target.y first: native.y flattens arch_x64.y and asm.y, and both call
// target_is_windows(), so the binding must be declared before the readers.
import wintgt from "../../../src/y/target.y";
import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";
import nemit from "../../../src/y/native.y";
print("all imports loaded");
let toks = lexer.tokenize("let x = 5;");
print("tokens = " + tostring(len(toks)));
let ast = parser.parse_program(toks);
print("parsed kind = " + ast.k);
let r = nemit.emit_program(ast, { src: "", imports: [], origin: { files: [""], nuser: 1, file: [], line: [], mods: [""] }, std: [], pkgs: [] }, false, 0, [], []);
print("asm ok = " + tostring(r.ok));
print("asm length = " + tostring(len(r.asm)));
