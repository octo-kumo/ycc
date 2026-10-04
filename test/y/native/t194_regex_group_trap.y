// std/regex.y: a group number past the last one is a caller bug, and it traps
// like any other index — the tree's rule for a reader into a fixed-shape record
// (struct.y:15). A NAME the pattern does not have is not a bug: it is a map
// read, and it gives none.
import regex;

let re = regex.compile("(\\d+)-(\\d+)")!;
let m = regex.search(re, "x 12-34 y")!;
print("group 1 ", regex.group(m, 1)!, " group 2 ", regex.group(m, 2)!);
// three groups is the whole match plus two, so 3 is past the end:
print("group 3 ", regex.group(m, 3)!);
print("not reached");