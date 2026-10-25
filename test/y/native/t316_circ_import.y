// A program one of whose modules imports IT BACK -- the cycle that used to be a
// hard error on a correct file.
//
// native_resolve_seen de-duplicates spliced modules through a `seen` list, and the
// PROGRAM was never in it. So this file was spliced once as the program and again
// when m316/circ.y imported it, and every declaration in it then stood in the tree
// twice: "duplicate definition ... defines it too" from the renamer, and "type ...
// is declared more than once" from the checker.
//
// It was never noticed because a program that imports its own module back is rare,
// and the one real case -- src/y/asm.y importing src/y/ir.y which imports asm.y --
// is never compiled on its own (asm.y is a unit of ycc.y). It surfaced through the
// language server, which checks the file a person has open, and showed them 32
// errors on a file `ycc ycc.y` compiles clean.
//
// The fix is native.resolve_unit passing the program's normalised path down as
// `self_path`, treated as already-spliced. It is passed BESIDE `seen` rather than
// inside it: `seen` is also the file-id counter, so seeding it would shift every
// module's id in origin.file and mis-attribute whole files -- that version stopped
// ycc.y and bignum.y compiling.

def VALUE() -> long { 7 }

import back from "./m316/circ.y";

print("value = " + tostring(VALUE()));
// Across the cycle both ways. The module's `prog.VALUE` has to reach this def, in
// the same flat namespace, with strip_ns flattening the qualifier -- and that is
// what the already-spliced branch records the namespace name for. Without it the
// module's `prog.` is left standing and every use of VALUE reports "undefined
// variable 'VALUE'", which is the same message the double splice produced.
print("round trip = " + tostring(back.seen(VALUE())));
print("and from the other side = " + tostring(back.side()));
