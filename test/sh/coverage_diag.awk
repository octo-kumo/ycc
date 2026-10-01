# test/sh/coverage_diag.awk — check 1 of test_coverage.sh: every message
# a diagnostic site of the compiler can print, and whether a test expects it.
#
#   awk -v EXCF=EXCUSES -v EXPF=EXPECT -f coverage_diag.awk EXCUSES EXPECT SRC...
#
#   EXCUSES  "file<TAB>code fragment" lines (COVERAGE.md, "Untested
#            diagnostics"): a site whose code line contains the fragment
#            needs no test
#   EXPECT   every line a test asserts (e*.y markers, the inline cases of
#            test/sh/*.sh, *.expected files)
#   SRC      the compiler sources, as src/y/... paths
#
# A site's message TEMPLATE is its constant text with a hole (*) for each
# dynamic part — `"cannot read field '" + k + "' of " + tstr(t)` is
# "cannot read field '*' of" (outer holes dropped). A test covers the site
# when one of its lines holds the whole template, holes matching anything:
# so a marker must quote the message through its last constant word.
#
# Prints one line per site, "STATUS<TAB>file:line<TAB>template-or-code":
#   tested    a test expects the message
#   excused   COVERAGE.md says why no test can
#   untested  neither
#   dynamic   no constant text to look for (fewer than 6 letters); only an
#             excuse covers it
# and "stale<TAB>file<TAB>fragment" for an excuse that excuses nothing.
#
# Sites (by source file):
#   lexer.y   puts("error: ...") and `err = "..."` (f-string errors)
#   parser.y  { k: "err"/"terr", msg: ... } nodes; expect_err(.., WHAT)
#             (prints "expected WHAT, got ...")
#   rename.y  { k: "err", msg: ... }
#   types.y   fail(st, MSG, ..); expect_type(.., WHAT, ..) and
#             expect_arg(.., WHAT, ..) (print "WHAT: expected T, got U");
#             `err = "..."` (format specs) and `fterr = "..."` (call
#             targets); the messages fmt_check returns
#   native.y  puts("error: ...") (imports, embeds); the duplicate-definition
#             error record
#   ycc.y     puts("error: ...") and puts("ycc: ...") (the driver)
#   anywhere  "runtime error: ..." (the trap messages compiled programs print)

BEGIN { HOLE = "\001" }

FILENAME == EXCF {
    split($0, a, "\t")
    if (a[2] != "") { nexc++; exf[nexc] = a[1]; exc[nexc] = a[2] }
    next
}
FILENAME == EXPF { ncorp++; corp[ncorp] = $0; next }

FNR == 1 { f = FILENAME; sub(/.*\/src\/y\//, "", f); infmt = 0 }
/^def / { infmt = (f == "types.y" && $0 ~ /^def fmt_check\(/) }
/^ *\/\// { next }

# The template of the Y expression starting at s[i]: its top-level string
# literal operands (unescaped) with every other operand a HOLE. It ends at
# a top-level , ; ) ] } or a comment.
function tmpl(s, i,    n, c, d, depth, out, lit, here, havelit, other) {
    n = length(s); depth = 0; out = ""; lit = ""; havelit = 0; other = 0
    while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\"") {
            here = ""; i++
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\\") {
                    d = substr(s, i + 1, 1)
                    here = here (d == "n" ? "\n" : d == "t" ? "\t" : d)
                    i += 2; continue
                }
                if (c == "\"") { i++; break }
                here = here c; i++
            }
            if (depth == 0 && !havelit && !other) { lit = here; havelit = 1 } else other = 1
            continue
        }
        if (c == "/" && substr(s, i + 1, 1) == "/") break
        if (depth == 0 && (c == "," || c == ";" || c == ")" || c == "]" || c == "}")) break
        if (c == "(" || c == "[" || c == "{") depth++
        else if (c == ")" || c == "]" || c == "}") depth--
        if (depth == 0 && c == "+") {
            out = out ((havelit && !other) ? lit : HOLE)
            lit = ""; havelit = 0; other = 0; i++; continue
        }
        if (c != " " && c != "\t") other = 1
        i++
    }
    return out ((havelit && !other) ? lit : HOLE)
}

# Start of the K-th top-level argument of the first call NAME(...) in s.
function callarg(s, name, k,    i, n, c, depth, ins) {
    i = index(s, name "(") + length(name) + 1
    n = length(s); depth = 0; ins = 0
    while (i <= n && k > 1) {
        c = substr(s, i, 1)
        if (ins) {
            if (c == "\\") i++
            else if (c == "\"") ins = 0
        } else if (c == "\"") ins = 1
        else if (c == "(" || c == "[" || c == "{") depth++
        else if (c == ")" || c == "]" || c == "}") depth--
        else if (c == "," && depth == 0) k--
        i++
    }
    return i
}

# Normalize a template: no "error: "/"ycc: " lead, newlines as holes, no
# outer holes or blanks, no doubled holes.
function norm(t) {
    sub(/^(error|ycc): /, "", t)
    gsub(/\n/, HOLE, t)
    gsub(HOLE "[ \t" HOLE "]*" HOLE, HOLE, t)
    sub("^[ \t" HOLE "]+", "", t)
    sub("[ \t" HOLE "]+$", "", t)
    return t
}

function rx(p,    out, i, c) {
    out = ""
    for (i = 1; i <= length(p); i++) {
        c = substr(p, i, 1)
        out = out (index("\\^$.[]|()*+?{}", c) ? "\\" c : c)
    }
    return out
}

function site(t,    code, k, n, parts, longest, re, j, txt, letters, ok) {
    if (t == "") return                      # `err = ""`: no message
    code = $0; sub(/^[ \t]+/, "", code)
    t = norm(t)
    txt = t; gsub(HOLE, "*", txt)
    letters = t; gsub("[^A-Za-z]", "", letters)
    if (length(letters) < 6) {
        for (k = 1; k <= nexc; k++)
            if (exf[k] == f && index(code, exc[k])) { used[k] = 1; print "excused\t" f ":" FNR "\t" code; return }
        print "dynamic\t" f ":" FNR "\t" code
        return
    }
    n = split(t, parts, HOLE); re = ""; longest = ""
    for (j = 1; j <= n; j++) {
        re = re (j > 1 ? ".*" : "") rx(parts[j])
        if (length(parts[j]) > length(longest)) longest = parts[j]
    }
    for (j = 1; j <= ncorp; j++)
        if (index(corp[j], longest) && corp[j] ~ re) { print "tested\t" f ":" FNR "\t" txt; return }
    for (k = 1; k <= nexc; k++)
        if (exf[k] == f && index(code, exc[k])) { used[k] = 1; print "excused\t" f ":" FNR "\t" txt; return }
    print "untested\t" f ":" FNR "\t" txt
}

# ---- the sites
index($0, "runtime error: ") {
    # a trap message: one literal, wherever it lives (an .ascii line in
    # arch_x64.y, a y_put_hstr call in std/rt.y)
    s = substr($0, index($0, "runtime error: "))
    sub(/\\.*/, "", s); sub(/".*/, "", s)
    site(s)
    next
}
f == "lexer.y" && /puts\("error: / { site(tmpl($0, index($0, "puts(") + 5)); next }
f == "lexer.y" && /err = "/ { site(tmpl($0, index($0, "err = ") + 6)); next }
f == "parser.y" && /k: "t?err", msg: / { site(tmpl($0, index($0, "msg: ") + 5)); next }
f == "parser.y" && /expect_err\(toks, [a-z_]+, "/ && !/^def / {
    site("expected " tmpl($0, callarg($0, "expect_err", 3)) ", got")
    next
}
f == "rename.y" && /k: "err", msg: / { site(tmpl($0, index($0, "msg: ") + 5)); next }
f == "types.y" && /fail\(st, / && !/^def / { site(tmpl($0, index($0, "fail(st, ") + 9)); next }
f == "types.y" && /expect_type\(/ && !/^def / {
    site(tmpl($0, callarg($0, "expect_type", 4)) ": expected " HOLE ", got")
    next
}
f == "types.y" && /expect_arg\(/ && !/^def / {
    site(tmpl($0, callarg($0, "expect_arg", 5)) ": expected " HOLE ", got")
    next
}
f == "types.y" && /(fterr|err) = "/ { site(tmpl($0, index($0, "= \"") + 2)); next }
f == "types.y" && infmt && /\{ "/ { site(tmpl($0, index($0, "{ \"") + 2)); next }
f == "types.y" && infmt && /^ *"/ { site(tmpl($0, index($0, "\""))); next }
f == "native.y" && /puts\("error: / { site(tmpl($0, index($0, "puts(") + 5)); next }
f == "native.y" && /\{ msg: "[^"]/ { site(tmpl($0, index($0, "msg: ") + 5)); next }
f == "ycc.y" && /puts\("(error|ycc): / { site(tmpl($0, index($0, "puts(") + 5)); next }

END {
    for (k = 1; k <= nexc; k++)
        if (!used[k]) print "stale\t" exf[k] "\t" exc[k]
}
