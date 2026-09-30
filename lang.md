# The Y language

A pointer into the real documentation:

* **`docs/`** — the formal definition (grammar, types, evaluation
  semantics), built with `cd docs && tectonic -X build`.
* **`src/y/NATIVE.md`** — how the native backend represents and lowers
  the language.
* **`README.md`**, **`AGENTS.md`**, **`PORTING.md`** — build, workflow and
  the twin-copy contract.

The notes below are the original sketch of the language and are kept as
history; where they disagree with `docs/`, `docs/` wins.

My language is C-like (so i use braces), with some mix of JS/TS-like features and some other random stuff from random languages.

No import/export system, single file only (for now). — obsolete: `import
x from "path"` and `import name;` splice the other file's text in front of
yours (see `docs/src/03-grammar.tex`).

Functions defined in global scope are exposed globally as labels.

Functions are supported as first-class citizens, and can be passed around as values.

```
{
    const add = def(a, b) {
        (a + b);
    };
    add(10, 20);
    const minus = def(a, b) {
        (a - b);
    };
    minus(30, add(10, minus(add((2000 * 2), (2 * (1 * (5 - (2 - (2 - 4)))))), 1)));
    print(""yooo"");
    3.141593;
}
```
