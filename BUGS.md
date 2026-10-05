# List of all bugs of YCC
Only include bugs of the compiler, make sure to include minimal reproduction.


***INSTRUCTIONS WHEN FINISH*** remove the BUG item from this file when it has been completed


## A field of an `if let`-narrowed binding loses its map/array type

When the value of an `if let` arm is produced *from* the narrowed binding's map-
or array-typed field, that field is seen as `void`. The rejection is spurious and
the diagnostic is wrong: `cannot index void (only arrays and maps)` fires for
`keys(x.v)`, where the source contains no index operation at all.

### Minimal reproduction

```y
type TA = { n: long };
type TC = { v: { str => long } };
type U = TA | TC;

def bad(u: U) -> [str] {
    if let TC c = u { return keys(c.v); }
    []
}
```

```
$ ycc bug.y -o bug
7:5: error: cannot index void (only arrays and maps)
```

### Verified matrix

Reproduced with `refs/ycc.ref`; deterministic across runs. Each case is
standalone — the four type declarations above plus one function.

**Fails:**

```y
// 1. keys() of the narrowed field, returned
def t1(u: U) -> [str] {
    if let TC c = u { return keys(c.v); }
    []
}

// 2. indexing the narrowed field, arm ends in a return
def t4(u: U) -> [str] {
    if let TC c = u { let k = "a"; if (is_some(c.v[k])) { return ["x"]; } }
    []
}

// 3. same, with the arm's value coming from an if/else
def t5(u: U) -> [str] {
    if let TC c = u { let k = "a"; if (is_some(c.v[k])) { ["x"] } else { [] } }
    ["y"]
}

// 4. binding the field to a local first does NOT help
def t7(u: U) -> [str] {
    if let TC c = u { let m = c.v; return keys(m); }
    []
}
```

**Compiles:**

```y
// 5. assign to an outer local, return after the arm
def t2(u: U) -> [str] {
    let r: [str] = [];
    if let TC c = u { r = keys(c.v); }
    r
}

// 6. keys() wrapped in another call
def t3(u: U) -> long {
    if let TC c = u { return len(keys(c.v)); }
    0
}

// 7. no narrowing: a plain parameter of the record type
def t6(c: TC) -> [str] { keys(c.v) }
```

Case 5 is the workaround: **never let the arm's value come from the narrowed
field — assign to a local declared outside the `if let` and read it after.**
Case 6 shows the field's type is correct when it is merely an argument, so the
loss is specific to the position, not to the binding. Case 7 shows narrowing is
what triggers it.

### Where the checker gets it wrong

Cases 2 and 3 index the field, so `cannot index void` is at least the right
*shape* of message — but the field is `{str => long}`, so `c.v[k]` is `long?`,
which is a perfectly valid map read. Case 1 and 4 never index anything, and
still get the indexing message.

### Workaround

As case 5. This is the shape `src/lsp/` code will have to use throughout, since
M4's symbol index narrows an AST node and reads its fields on nearly every node
kind.

### Why it matters here

Found while writing `src/y/std/json.y` (`LSP.md` §15), which calls `keys()` on
every object it emits.

### Suspected cause

Untraced. The field's type is right when it is an argument (case 6) and right
when read after the arm (case 5), and wrong when the arm's value derives from
it — so the narrowing's environment appears to be popped, or the expected type
of the arm's value installed, before the field's type is looked up. The
diagnostic text suggests the lookup yields void, which `keys`'s argument check
and the index check both then report as a non-array/non-map.
---

## `import fs;` twice resolves to two files, so every `fs.y` def is a duplicate

`native.norm_path` drops `.` from a path but never collapses `..`. So the same
file reached by two different spellings normalises to two different strings, the
import splicer's `seen` check misses, and `fs.y` is spliced twice.

This only bites when a program imports a module **by path from a different
directory** than the std modules resolve from — which is to say, only when you
write a tool outside `src/y/`. `src/y/ycc.y` gets away with it because its own
`import fs;` and `native.y`'s resolve to the same string.

### Minimal reproduction

The two files go where the tool actually lives, because the `..` has to be in the
path for the bug to appear at all — with an absolute import path the same two
imports also collide, but the message reads differently.

```console
$ printf 'import n from "../../y/native.y";\ndef helper() -> long { 1 }\nexport { helper };\n' > src/tools/lsp/_bug_m.y
$ printf 'import fs;\nimport m from "./_bug_m.y";\nprint(m.helper());\n' > src/tools/lsp/_bug_p.y
$ ycc src/tools/lsp/_bug_p.y -o /tmp/p
```

**97 errors**, one per name in `fs.y` (both spellings of each, and it does not
stop at the first). The first, verbatim:

```
src/tools/lsp/../../y/std/fs.y:18:1: error: duplicate definition 'fs.fs_at_cwd': src/y/std/fs.y:18 defines it too (imported files share one namespace; rename one)
src/tools/lsp/../../y/std/fs.y:21:1: error: duplicate definition 'fs.open_flags': src/y/std/fs.y:21 defines it too (imported files share one namespace; rename one)
```

Note the two sides: the same file, one reached as
`src/tools/lsp/../../y/std/fs.y` and one as `src/y/std/fs.y`.

Remove the path import and it compiles clean (`import fs;` alone is fine).
Remove the top-level `import fs;` and the `fs.y` duplicates are gone too — that
build then fails for an unrelated reason (`enc64.y`'s `rip`/`lbl` intrinsics,
which is a separate in-flight matter), so the honest statement is that the
duplicate errors stop, not that the build succeeds. It is the pair that
triggers it.

### Why

`std_resolve` returns `norm_path(candidate)`, and

```y
def norm_path(p: str) -> str {
    let parts = split(p, "/");
    let out: [str] = [];
    // ... skips "." segments only, never folds ".." into the previous one
    join(out, "/")
};
```

The two callers spell the file differently:

* the program's own `import fs;` → base dir is the program dir, and a later
  candidate is `src/y/std/fs.y`, so it normalises to `src/y/std/fs.y`;
* `native.y`'s `import fs;` → base dir is the directory `native.y` was *reached
  through*, `src/tools/lsp/../../y`, so the winning candidate is
  `src/tools/lsp/../../y/std/fs.y`, and `norm_path` leaves the `..` in place.

Two strings, one file. `native_resolve_seen` compares the normalised paths, finds
no match, and splices `fs.y` a second time under the same qualified names.

### Suspected fix

Fold `..` in `norm_path`, the way it already folds `.`: when a segment is `..`,
drop the segment before it if there is one and it is not itself `..`. Keep a
leading `..` (a relative path may genuinely point above the cwd).

```y
if (seg == "..") {
    if (len(out) > 0 && out[len(out) - 1] != "..") { out = out[0:len(out) - 1]; }
    else { out += seg; }
}
```

That makes both callers normalise to `src/y/std/fs.y`, and the dedupe works.

### Workaround until then

Import a by-name std module **once**, from whichever module also pulls in the
path-imported one. `src/tools/lsp/` does this: `diag.y` imports `native.y` by
path, `native.y` brings `fs` in by name, and neither `rpc.y` nor `serve.y`
imports `fs` at all. The cost is that `rpc.y` cannot be used on its own without
the caller supplying `fs`, which its test fixture has to do explicitly.

### Why it matters here

M1 (`src/tools/lsp/`). `yserve.y` needs `fs` for the framing layer, and its test
fixtures need to read files; both want an `import fs;` that cannot be written.

### Not this

Not the by-name/path import asymmetry (by-name std imports keep their namespace,
path imports are flattened) — that one behaves as documented and `LSP.md` §5
records it. This is purely a string-comparison failure in `norm_path`.

---

## A duplicate `def` in the SAME file is not an error; the last one silently wins

`find_dup` only compares definitions **across** files. Two top-level `def`s with
the same name in one file compile without a word, and the later one takes the
name — so a copy-paste that leaves an old copy behind silently replaces the
behaviour of the new one, with no diagnostic anywhere.

### Minimal reproduction

```console
$ printf 'def f() -> long { 1 }\ndef f() -> long { 2 }\nprint(f());\n' > /tmp/dup.y
$ ycc /tmp/dup.y -o /tmp/dup && /tmp/dup
```

Prints `2`. No error, no warning. The cross-file case *is* reported — two
modules each defining `is_punct` gives

```
scan.y:62:1: error: duplicate definition 'is_punct': parser.y:138 defines it too
(imported files share one namespace; rename one)
```

so the check exists and simply does not look inside a file it has already
accepted.

### Why it matters

This cost an afternoon of "my code is not running and I cannot see why". A
`python` edit that rewrote a region of a file left **two** copies of `symbols`
and **three** of `add_child`; the compiler reported nothing; the stale `symbols`
— the version *without* a fix — shadowed the new one on every call. Every read of
the source showed the correct code, and every run used the other one. The only
thing that gave it away was counting definitions:

```console
$ grep -n '^def symbols\|^def add_child' src/tools/lsp/sym.y
167:def add_child(...)
190:def opens_guard_block(...)
217:def symbols(...)
320:def add_child(...)
333:def symbols(...)
435:def add_child(...)
```

### Suspected fix

`find_dup` already walks `ast.stmts` per file. It needs a per-file pass as well:
key each top-level `def`/`const`/`type`/`export` name by its own file and report
a second occurrence with a message in the same shape as the cross-file one. The
same pass would catch a duplicated `import`, which is also currently silent.

### Not this

Not the flattening of path imports (that is documented and intentional, and it is
what makes the cross-file case possible at all). This is a missing check, not a
wrong one.
