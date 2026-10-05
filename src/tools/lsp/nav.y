// nav.y -- M4: the word under the cursor, and the declaration it names.
//
// Stage A, and deliberately so: everything here comes from spans and from
// declarations the index actually found. Nothing is inferred, nothing is
// guessed from a type, and a name that is not declared answers "not found"
// rather than the nearest thing that looks like it. The alternative -- resolve
// through the compiler's own symbol tables -- is Stage B (LSP.md §9, C2) and
// costs a compiler change; see LSP.md R5 for why the honest answer is worth
// having first.
//
// What this CAN answer, all from index.y's declarations:
//   - go to definition, for any name the file declares (locals, parameters,
//     top-level and nested defs and lets, type aliases, imports)
//   - hover, as the declaration's signature plus the comment above it
//   - completion, as the names visible at the cursor plus the builtins
//
// What it cannot, and says so rather than guessing:
//   - a name from ANOTHER file (an imported module's members), a std unit's
//     members, or a string method after a `.`. Those need the program's real
//     scope, which is Stage B.

import scan from "./scan.y";
import pos from "./pos.y";
import scope from "./scope.y";

// ── the word under the cursor ────────────────────────────────────────────

// An identifier the cursor is inside or touching. `end` is exclusive.
// `line`/`ch` are the word's own 0-based LSP position, which is what hover's
// range is: the client underlines the WORD, not the declaration it resolves to.
type Hit = { name: str, off: long, end: long, line: long, ch: long };

// The identifier span covering byte offset `off`.
//
// The test is `s.off <= off <= s.end`, INCLUSIVE of the end, and that is the
// whole reason a caret after the last letter works: an editor asking about
// `foo` with the caret at the end of `foo` means `foo`, not the token after it.
// (A caret one further right, past the end, is a different offset and matches
// nothing -- the right answer for a position that is not on a name.)
//
// Only K_ident is considered. A keyword or a contextual word under the cursor
// is not a name to resolve, and a string or a comment is text.
def ident_at(sps: [Span], src: str, off: long) -> Hit? {
    let out: Hit? = none;
    let i = 0;
    while (i < len(sps)) {
        let s = sps[i];
        if (s.kind == scan.K_ident && off >= s.off && off <= s.end) {
            let p = pos.to_lsp(src, s.line, s.col);
            out = some({ name: src[s.off:s.end], off: s.off, end: s.end, line: p.line, ch: p.character });
            break;
        };
        i = i + 1;
    };
    out
}

// ── visibility ───────────────────────────────────────────────────────────
//
// Positions are compared through `scope.pack`, which folds a (line, character)
// pair into one number: a packed position orders the same way the pair does, as
// long as a character is under a million, which a UTF-16 offset within one line
// cannot be. So one `<` is the whole comparison.

// Whether a use at (line, ch) can see `d`.
//
// Two rules, and they are not the same rule:
//
//   SCOPE. A declaration belongs to the block its name was written in.
//   scope.y records where that block OPENS (`scope_start`, -1 at top level) and
//   scope.scope_end where it CLOSES, so a use is inside exactly when it is at
//   or after the open and at or before the close. Both ends matter, and leaving
//   out the close is not a harmless imprecision: with only the open, a `let`
//   inside one function stayed visible for the rest of the file, and since the
//   inner declaration is the DEEPER one it won -- so `print(shared)` after a
//   function with its own `shared` resolved to that function's variable.
//
//   ORDER. A `let` is only visible after its own line; Y has no hoisting for
//   one, and reading it earlier is `undefined variable`. A `def` IS hoisted
//   (that is what makes mutual recursion work), so a def may be used before it
//   is written and must be offered there.
def in_scope(idx: FileIdx, d: IdxDecl, line: long, ch: long) -> bool {
    let here = scope.pack(line, ch);
    let there = scope.pack(d.line, d.ch);
    let opened = true;
    if (d.scope_start >= 0) {
        let endp = scope.scope_end(idx.closed, d.scope_start);
        opened = here >= d.scope_start && (endp < 0 || here <= endp);
    };
    if (!opened) { false }
    else if (d.kind == scope.D_LET || d.kind == scope.D_CONST || d.kind == scope.D_PARAM) {
        here >= there
    } else { true }
};

// Two declarations of one name, both visible at the same use: does `a` win over
// `b`?
//
// The deeper one does, because it shadows. At equal depth the LATER one does,
// and that is the compiler's own answer rather than a tidier rule: a name
// declared twice at one level is not an error, and the last binding is the one
// the rest of the unit sees (for a repeated top-level `def`, BUGS.md 3, the last
// definition silently replaces the first). Jumping to the earlier one would land
// on code the compiler discarded.
//
// `line`/`ch` are the use's position and are not consulted: two same-depth
// declarations are both either before the use (or `def`s, hoisted) or neither,
// so order is decided between them and the use only matters for picking a
// candidate at all (in_scope).
def better(a: IdxDecl, b: IdxDecl, line: long, ch: long) -> bool {
    if (a.depth != b.depth) { a.depth > b.depth }
    else { scope.pack(a.line, a.ch) > scope.pack(b.line, b.ch) }
};

// The declaration `name` resolves to at a use at (line, ch), or none.
//
// Scans every declaration rather than stopping at the first match: a name
// declared in three nested blocks has three candidates and only the innermost
// is the answer, and "first found" is whichever the index happened to record
// first, which is source order and not scope order.
def find_decl(idx: FileIdx, name: str, line: long, ch: long) -> IdxDecl? {
    let best: IdxDecl? = none;
    let i = 0;
    while (i < len(idx.decls)) {
        let d = idx.decls[i];
        if (d.name == name && in_scope(idx, d, line, ch)) {
            if (best == none) {
                best = some(d);
            } else {
                let b: IdxDecl = best!;
                if (better(d, b, line, ch)) { best = some(d); };
            };
        };
        i = i + 1;
    };
    best
};

// ── completion ───────────────────────────────────────────────────────────

// Every name visible at (line, ch), each ONCE, innermost declaration first.
//
// Deduplicated by name because a name in three nested scopes is one thing to
// type, and offering it three times is noise. The representative kept is the
// best one -- the same ranking find_decl uses -- so the detail shown beside
// completion item is the declaration that would actually be jumped to.
def visible(idx: FileIdx, line: long, ch: long) -> [IdxDecl] {
    let names: [str] = [];
    let out: [IdxDecl] = [];
    let i = 0;
    while (i < len(idx.decls)) {
        let d = idx.decls[i];
        if (in_scope(idx, d, line, ch)) {
            let seen = false;
            let k = 0;
            while (k < len(names)) {
                if (names[k] == d.name) { seen = true; };
                k = k + 1;
            };
            if (!seen) {
                names += d.name;
                out += d;
            } else {
                let k2 = 0;
                while (k2 < len(out)) {
                    if (out[k2].name == d.name) {
                        if (better(d, out[k2], line, ch)) { out = out[0:k2] + [d] + out[k2 + 1:len(out)]; };
                    };
                    k2 = k2 + 1;
                };
            };
        };
        i = i + 1;
    };
    out
}

// The names a use at (line, ch) can see, filtered to a prefix. The prefix match
// is on the name's own bytes, so `in` offers `index_of` and `is_some` and not
// `join`; an empty prefix (the user has typed nothing yet) offers everything.
def with_prefix(ds: [IdxDecl], prefix: str) -> [IdxDecl] {
    let out: [IdxDecl] = [];
    let i = 0;
    while (i < len(ds)) {
        let d = ds[i];
        if (prefix == "" || (len(d.name) >= len(prefix) && d.name[:len(prefix)] == prefix)) {
            out += d;
        };
        i = i + 1;
    };
    out
}

export { Hit, ident_at, in_scope, better, find_decl, visible, with_prefix };
