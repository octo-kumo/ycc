// expect-error: m133/m.y:9:23: error: let 's': expected str, got long
// expect-error: 9:1: error: let 'after': expected long, got str
// An error in an imported module names the module's file and its own
// line; one in the program keeps its own line, however much text the
// imports splice in above it.
import m from "m133/m.y";

print(m.six());
let after: long = "x";
