// target.y first, before the modules that call target_is_windows(): native.y
// pulls in arch_x64.y and asm.y, and a path import is flattened, so the
// binding has to exist before the reader is compiled (ycc.y imports it in the
// same place).
import wintgt from "../../../src/y/target.y";
import lexer from "../../../src/y/lexer.y";
import parser from "../../../src/y/parser.y";
import native from "../../../src/y/native.y";

print("imports loaded");
let src = "let x = 5;";
let toks = lexer.tokenize(src);
print("tokens = " + tostring(len(toks)));
