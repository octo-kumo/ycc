// embed NAME from "path": the file's bytes as a str const, read at compile
// time, the path relative to the file that says it (m66/embed_mod.y embeds
// a file next to itself). The literal stays on the declaration's one line,
// so line numbers after it hold (e57 checks that). The data file carries a
// quote, backslashes, a tab, `//` and `/* */`, a control byte, UTF-8, a CR
// and no final newline.
import m from "./m66/embed_mod.y";
embed DATA from "t66_embed.txt";

print(DATA);
print(len(DATA));
let parts = split(DATA, "\n");
print(len(parts));
print(parts[1]);
let k = index_of(DATA, "ctrl:") + 5;
let b = bytes(DATA);
let v: long = b[k];
print(v);
print(DATA[len(DATA) - 7:]);
print(m.word());
