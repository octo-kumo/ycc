// flags: -W 1
// A bare `import name;` that nothing in the file uses is a level-1 warning at
// the import's own line. `name.` anywhere else in the file counts as a use
// (a call, a constant, or a type `m.T`); a mention in a `//` comment, or as the
// tail of a longer name, does not.
import fs; // expect-warning: unused import 'fs'
import math;
import sort; // expect-warning: unused import 'sort'
// math.sqrt in a comment is not a use, but the line below is
print(math.sqrt(16.0));
let xfs = 1;
print(xfs + 1);
