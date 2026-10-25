// A module's type aliases are reached through its name: bare, they are
// unknown to the program.
// expect-error: 6:1: error: unknown type 'Square'
// expect-error: 7:1: error: unknown type 'm157.Triangle'
import m157;
let a: Square = m157.unit();
let b: m157.Triangle = m157.unit();
