// strm.y -- the string methods, for hover and completion after a `.
//
// LSP.md R6.1 asks completion for "record fields of the expression before the
// dot", and R6.2 for the string methods among the globals. The compiler already
// HAS the answer: `types.str_method(m)` returns the method's parameters, its
// arity and its return type, and `fn == ""` for a name that is not a method. So
// this module does not describe a method -- it asks.
//
// The one thing it cannot do is ENUMERATE. `str_method` is a chain of string
// comparisons, so there is no list to walk and a caller that wants "every method"
// has to know the names. Hence MIRROR below, which is this file's own copy of the
// names.
//
// A mirror is exactly the kind of copy that rots, so it is filtered through the
// compiler on every use: `names()` drops any name `str_method` does not
// recognise, and `find` is the compiler's answer rather than this file's.
//
// That makes ONE direction automatic and leaves the other to a test, and it is
// worth being exact about which is which:
//
//   compiler -> mirror  automatic. A method RENAMED or REMOVED in types.y stops
//     being recognised, so `names()` drops it and completion stops offering it.
//     Nothing here is edited and nothing breaks: the list is simply shorter.
//
//   mirror -> compiler  a test's job. A method ADDED to types.py that nobody adds
//     to MIRROR is invisible to completion and to every check in this file --
//     `has` and `names()` are both driven BY the mirror, so they cannot see a
//     name that is not in it. t014_strm is what catches that: it prints the
//     accepted set and the count into its expectation, so a method appearing in
//     types.y shows up as a failed suite rather than as a silent gap. It is a
//     ratchet, not a proof -- the assertion that FAILS automatically is the other
//     direction -- and it is stated here rather than left for a reader to
//     discover by wondering why nothing catches an addition.
//
// The names come from types.y's own str_method chain, aliases included
// (`trim`/`strip`, `lstrip`/`trim_start`, `rstrip`/`trim_end`): those are real
// spellings a program may use, and they belong in a completion list.
// target.y before types.y, for the reason diag.y's header spells out: types.y
// calls target_is_windows(), and a path import is flattened, so the binding
// must be declared before the reader that needs it is compiled.
import wintgt from "../../y/target.y";
import types from "../../y/types.y";

// This file's copy of the names. See the header: filtered through str_method on
// every use, so it cannot offer a name the compiler has stopped accepting.
const MIRROR: [str] = ["split", "join", "trim", "strip", "trim_start", "lstrip",
    "trim_end", "rstrip", "pad_left", "pad_right", "center", "starts_with",
    "ends_with", "contains", "index_of", "last_index_of", "count", "replace",
    "upper", "lower", "repeat", "lines", "bytes", "tolong", "tofloat", "ord",
    "byte_at"];
//
// No `length`: `s.length` is a PROPERTY (NATIVE.md, "Owned strings"), not a
// method, and str_method does not list it -- putting it in the mirror would make
// names() build 27 and return 26, which reads as a bug in the filter rather than
// as the mirror being wrong.

// The method `name`, or none. This IS the compiler's answer: str_method's `fn`
// is empty for a name it does not know, which is how it says so.
//
// Named `method_of` rather than `find`: a path import flattens, and the compiler
// already has a `find` (regex.y) and a `has` (args.y), so either name is a
// duplicate definition the moment anything imports both. `ytest check-names` is what
// catches it, and it is in this suite.
def method_of(name: str) -> StrMethod? {
    let out: StrMethod? = none;
    let sm = str_method(name);
    if (sm.fn != "") { out = some(sm); };
    out
};

// Is `name` a string method? The predicate `str_method` gives for free.
def is_method(name: str) -> bool {
    is_some(method_of(name))
}

// The mirror, minus anything the compiler no longer accepts.
def names() -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(MIRROR)) {
        if (is_method(MIRROR[i])) { out += MIRROR[i]; };
        i = i + 1;
    };
    out
}

// `split(str) -> [str]` -- the signature as a hover shows it.
//
// Three things are worth saying about what is NOT here, because each was wrong
// before and the compiler's own table is what corrected it. types.y, the comment
// above `type StrMethod`, is the authority:
//
//   * Parameter NAMES. The table records types, not names -- `split` is `[str]`
//     here and `split(sep: str)` in the manual -- so none are invented here.
//     `tstr` of the recorded type is the whole of what is known.
//   * `dflt` is the VALUE of the trailing default, not source text, and the
//     parameter's TYPE says how to write it: the emitter makes a string
//     literal for a str parameter and a numeric one for a long, so `pad_left`
//     reads `pad_left(long, str = " ") -> str` and `index_of` reads
//     `index_of(str, long = 0) -> long`.
//   * `last` is NOT variadic, which is what a first pass here rendered it as. It
//     says the receiver goes AFTER the arguments (`sep.join(xs)` is
//     `join(xs, sep)`), which is the emitter's argument order and not part of
//     how a method is written. `join` is the only method that sets it, and it
//     renders `join([T]) -> str` like every other one.
//
// An unknown name gives `name(?) -> ?`, never a half-written `name(`.
def sig(name: str) -> str {
    let got = method_of(name);
    if (!is_some(got)) { return name + "(?) -> ?"; };
    let sm: StrMethod = got !;
    let out = name + "(";
    let i = 0;
    let req = sm.nreq;
    while (i < len(sm.params)) {
        if (i > 0) { out = out + ", "; };
        out = out + tstr(sm.params[i]);
        if (i >= req) {
            if (tstr(sm.params[i]) == "long") {
                out = out + " = " + sm.dflt;
            } else {
                out = out + " = \"" + sm.dflt + "\"";
            };
        };
        i = i + 1;
    };
    out = out + ") -> " + tstr(sm.ret);
    out
}

// The methods whose name starts with `prefix`, as completion items want them.
//
// Named `matching`, not `with_prefix`: a path import FLATTENS, and nav.y already
// has a `with_prefix(xs, prefix)` of its own. Two functions of one name in the
// spliced program is a duplicate definition reported against whichever file the
// compiler happens to reach second.
// An empty prefix (nothing typed yet) offers all of them.
def matching(prefix: str) -> [str] {
    let out: [str] = [];
    let all = names();
    let i = 0;
    while (i < len(all)) {
        let nm = all[i];
        if (prefix == "" || (len(nm) >= len(prefix) && nm[:len(prefix)] == prefix)) {
            out += nm;
        };
        i = i + 1;
    };
    out
}

export { MIRROR, method_of, is_method, names, sig, matching };
