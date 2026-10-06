/* tags.c -- 1:1 C copy of src/y/tags.y (translation contract:
 * PORTING.md). The enum is in tags.h; this is the reverse direction,
 * for the four places a tag reaches a diagnostic text, and the check
 * that the two tables have not drifted. */
#include "yv.h"
#include "tags.h"

static const char *const ktags[] = {
    "a", "addr", "array", "arrrep", "assign", "bad", "bin", "block", "bool",
    "bstr", "call", "char", "decl", "deref", "diff", "dot", "dotassign",
    "err", "file", "for", "foreach", "forrange", "fs", "func", "git", "h",
    "id", "idxassign", "if", "imm", "incdec", "ind", "index", "kw", "lbl",
    "loc", "map", "matchend", "mem", "narrow", "num", "opassign", "optarg",
    "path", "rec", "rectest", "reg", "ret", "rev", "s", "slice",
    "sliceassign", "store", "str", "t", "tarr", "tarrfix", "tbool", "tbyte",
    "terr", "tfloat", "tfunc", "tinfer", "tlong", "tmap", "tname", "tnone",
    "topt", "tparams", "tpat", "tpend", "tptr", "trec", "tref", "tstr",
    "tunion", "tunk", "tvoid", "typedef", "un", "void", "while",
    "break", "continue"
};

Yv *ktag(long n) {
    if (n >= 1 && (size_t)n <= sizeof(ktags) / sizeof(ktags[0])) {
        return ys_cstr(ktags[n - 1]);
    }
    return ys("");
}

/* ── how deep the recursive walks may nest ────────────────────────────────
 * 1:1 with the MAX_NEST block in src/y/tags.y (whose comment says why 1000
 * and what it replaces: nesting past it ended in a raw SIGSEGV, and at a
 * different depth in each copy). Every walk that follows the tree -- the
 * parser, the renamer, the checker, the emitter -- counts its depth here,
 * at its own entry, so `yv_nest` is a plain long as `nest` is a top-level
 * one in Y. No reset between phases: every walk that enters also leaves. */
long yv_nest = 0;

Yv *nest_reset(void) { yv_nest = 0; return yv_long(0); }

Yv *too_deep(Yv *what, Yv *line, Yv *col) {
    Yv *msg = ys_cat(ys_cat(ys_long(yv_l(line)), ys(":")),
                     ys_long(yv_l(col)));
    msg = ys_cat(ys_cat(msg, ys(": error: ")), what);
    msg = ys_cat(ys_cat(msg, ys(" nests deeper than ")),
                 ys_long(MAX_NEST));
    puts_(ys_cat(msg, ys(", the compiler's limit\n")));
    exit_(1);
    return yv_long(0);
}

int max_nest_agree(void) { return MAX_NEST == 1000; }

int tags_agree(void) {
    if (!ys_eq_lit(ktag(K_a), "a")) { return 0; }
    if (!ys_eq_lit(ktag(K_addr), "addr")) { return 0; }
    if (!ys_eq_lit(ktag(K_array), "array")) { return 0; }
    if (!ys_eq_lit(ktag(K_arrrep), "arrrep")) { return 0; }
    if (!ys_eq_lit(ktag(K_assign), "assign")) { return 0; }
    if (!ys_eq_lit(ktag(K_bad), "bad")) { return 0; }
    if (!ys_eq_lit(ktag(K_bin), "bin")) { return 0; }
    if (!ys_eq_lit(ktag(K_block), "block")) { return 0; }
    if (!ys_eq_lit(ktag(K_bool), "bool")) { return 0; }
    if (!ys_eq_lit(ktag(K_bstr), "bstr")) { return 0; }
    if (!ys_eq_lit(ktag(K_call), "call")) { return 0; }
    if (!ys_eq_lit(ktag(K_char), "char")) { return 0; }
    if (!ys_eq_lit(ktag(K_decl), "decl")) { return 0; }
    if (!ys_eq_lit(ktag(K_deref), "deref")) { return 0; }
    if (!ys_eq_lit(ktag(K_diff), "diff")) { return 0; }
    if (!ys_eq_lit(ktag(K_dot), "dot")) { return 0; }
    if (!ys_eq_lit(ktag(K_dotassign), "dotassign")) { return 0; }
    if (!ys_eq_lit(ktag(K_err), "err")) { return 0; }
    if (!ys_eq_lit(ktag(K_file), "file")) { return 0; }
    if (!ys_eq_lit(ktag(K_kw_for), "for")) { return 0; }
    if (!ys_eq_lit(ktag(K_kw_foreach), "foreach")) { return 0; }
    if (!ys_eq_lit(ktag(K_forrange), "forrange")) { return 0; }
    if (!ys_eq_lit(ktag(K_fs), "fs")) { return 0; }
    if (!ys_eq_lit(ktag(K_func), "func")) { return 0; }
    if (!ys_eq_lit(ktag(K_git), "git")) { return 0; }
    if (!ys_eq_lit(ktag(K_h), "h")) { return 0; }
    if (!ys_eq_lit(ktag(K_id), "id")) { return 0; }
    if (!ys_eq_lit(ktag(K_idxassign), "idxassign")) { return 0; }
    if (!ys_eq_lit(ktag(K_kw_if), "if")) { return 0; }
    if (!ys_eq_lit(ktag(K_imm), "imm")) { return 0; }
    if (!ys_eq_lit(ktag(K_incdec), "incdec")) { return 0; }
    if (!ys_eq_lit(ktag(K_ind), "ind")) { return 0; }
    if (!ys_eq_lit(ktag(K_index), "index")) { return 0; }
    if (!ys_eq_lit(ktag(K_kw), "kw")) { return 0; }
    if (!ys_eq_lit(ktag(K_lbl), "lbl")) { return 0; }
    if (!ys_eq_lit(ktag(K_loc), "loc")) { return 0; }
    if (!ys_eq_lit(ktag(K_map), "map")) { return 0; }
    if (!ys_eq_lit(ktag(K_matchend), "matchend")) { return 0; }
    if (!ys_eq_lit(ktag(K_mem), "mem")) { return 0; }
    if (!ys_eq_lit(ktag(K_narrow), "narrow")) { return 0; }
    if (!ys_eq_lit(ktag(K_num), "num")) { return 0; }
    if (!ys_eq_lit(ktag(K_opassign), "opassign")) { return 0; }
    if (!ys_eq_lit(ktag(K_optarg), "optarg")) { return 0; }
    if (!ys_eq_lit(ktag(K_path), "path")) { return 0; }
    if (!ys_eq_lit(ktag(K_rec), "rec")) { return 0; }
    if (!ys_eq_lit(ktag(K_rectest), "rectest")) { return 0; }
    if (!ys_eq_lit(ktag(K_reg), "reg")) { return 0; }
    if (!ys_eq_lit(ktag(K_ret), "ret")) { return 0; }
    if (!ys_eq_lit(ktag(K_rev), "rev")) { return 0; }
    if (!ys_eq_lit(ktag(K_s), "s")) { return 0; }
    if (!ys_eq_lit(ktag(K_slice), "slice")) { return 0; }
    if (!ys_eq_lit(ktag(K_sliceassign), "sliceassign")) { return 0; }
    if (!ys_eq_lit(ktag(K_store), "store")) { return 0; }
    if (!ys_eq_lit(ktag(K_str), "str")) { return 0; }
    if (!ys_eq_lit(ktag(K_t), "t")) { return 0; }
    if (!ys_eq_lit(ktag(K_tarr), "tarr")) { return 0; }
    if (!ys_eq_lit(ktag(K_tarrfix), "tarrfix")) { return 0; }
    if (!ys_eq_lit(ktag(K_tbool), "tbool")) { return 0; }
    if (!ys_eq_lit(ktag(K_tbyte), "tbyte")) { return 0; }
    if (!ys_eq_lit(ktag(K_terr), "terr")) { return 0; }
    if (!ys_eq_lit(ktag(K_tfloat), "tfloat")) { return 0; }
    if (!ys_eq_lit(ktag(K_tfunc), "tfunc")) { return 0; }
    if (!ys_eq_lit(ktag(K_tinfer), "tinfer")) { return 0; }
    if (!ys_eq_lit(ktag(K_tlong), "tlong")) { return 0; }
    if (!ys_eq_lit(ktag(K_tmap), "tmap")) { return 0; }
    if (!ys_eq_lit(ktag(K_tname), "tname")) { return 0; }
    if (!ys_eq_lit(ktag(K_tnone), "tnone")) { return 0; }
    if (!ys_eq_lit(ktag(K_topt), "topt")) { return 0; }
    if (!ys_eq_lit(ktag(K_tparams), "tparams")) { return 0; }
    if (!ys_eq_lit(ktag(K_tpat), "tpat")) { return 0; }
    if (!ys_eq_lit(ktag(K_tpend), "tpend")) { return 0; }
    if (!ys_eq_lit(ktag(K_tptr), "tptr")) { return 0; }
    if (!ys_eq_lit(ktag(K_trec), "trec")) { return 0; }
    if (!ys_eq_lit(ktag(K_tref), "tref")) { return 0; }
    if (!ys_eq_lit(ktag(K_tstr), "tstr")) { return 0; }
    if (!ys_eq_lit(ktag(K_tunion), "tunion")) { return 0; }
    if (!ys_eq_lit(ktag(K_tunk), "tunk")) { return 0; }
    if (!ys_eq_lit(ktag(K_tvoid), "tvoid")) { return 0; }
    if (!ys_eq_lit(ktag(K_typedef), "typedef")) { return 0; }
    if (!ys_eq_lit(ktag(K_un), "un")) { return 0; }
    if (!ys_eq_lit(ktag(K_void), "void")) { return 0; }
    if (!ys_eq_lit(ktag(K_kw_while), "while")) { return 0; }
    if (!ys_eq_lit(ktag(K_kw_break), "break")) { return 0; }
    if (!ys_eq_lit(ktag(K_kw_continue), "continue")) { return 0; }
    return 1;
}
