// The module t316_circ_import.y imports, which imports THAT PROGRAM BACK. Legal --
// they are separate units and a unit may be imported by more than one -- and it is
// also a program in its own right, so the port gate compiles this file too and the
// cycle is checked from BOTH ends. Both ends matter and they take different paths
// through the de-duplication: compiled as the program, the cycle reaches `seen`;
// compiled as t316_circ_import.y, this file is reached through `self_path`.
//
// `prog.VALUE` has to reach a `def` in the program this file is spliced into, in
// the same flat namespace, with strip_ns flattening the qualifier. All defs, so
// neither file depends on where the splice put the other's text -- a module's
// lines land where the import line was, so it can name a `def` wherever that def
// sits but a top-level `let` only if the `let` came earlier in the file.

import prog from "../t316_circ_import.y";

def side() -> long {
    prog.VALUE() * 100
}

def seen(n: long) -> long {
    prog.VALUE() * 10 + n
}

print("the module alone: side = " + tostring(side()) + ", seen = " + tostring(seen(prog.VALUE())));
export { side, seen };
