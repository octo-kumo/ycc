// One ordered vocabulary generates both the numeric fields and diagnostic names.
// Append new tags to preserve the numbers stored in packs.
#{
    let names = ("a addr array arrrep assign bad bin block bool bstr call char decl deref diff dot dotassign err file for foreach forrange fs func git h id idxassign if imm incdec ind index kw lbl loc map matchend mem narrow num opassign optarg path rec rectest reg ret rev s slice sliceassign store str t tarr tarrfix tbool tbyte terr tfloat tfunc tinfer tlong tmap tname tnone topt tparams tpat tpend tptr trec tref tstr tunion tunk tvoid typedef un void while break continue bignum tbigint punct op bigint ferr fstr eof comment stray doc tint tpack").split(" ");
    let fields = "";
    let quoted = "";
    for i in 0..len(names) {
        let name = names[i];
        let field = name;
        if (name in ["for", "foreach", "if", "while", "break", "continue"]) {
            field = "kw_" + name;
        };
        if (i > 0) { fields += ","; quoted += ","; };
        fields += field + ":" + tostring(i + 1);
        quoted += "\"" + name + "\"";
    };
    "const K = {" + fields + "};\n" +
    "const KTAGS: [str] = [" + quoted + "];\n" +
    "def ktag(n: long) -> str { KTAGS[n - 1] };\n"
}#

// ── how deep the recursive walks may nest ────────────────────────────────
const MAX_NEST = 1000;

let nest = 0;

def nest_reset() { nest = 0; 0 };

// Past the limit: say what was too deep and stop. `what` names the walk
// ("an expression", "a type", "a statement"), since a program can be too deep
// in more than one way.
def too_deep(what: str, line: long, col: long) -> void {
    puts(tostring(line) + ":" + tostring(col) + ": error: " + what +
        " nests deeper than " + tostring(MAX_NEST) + ", the compiler's limit\n");
    exit(1);
};

export { K, KTAGS, ktag, MAX_NEST, nest, nest_reset, too_deep };
