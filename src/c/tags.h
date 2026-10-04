/* tags.h -- the compiler's one vocabulary of tags.
 * 1:1 C copy of src/y/tags.y (see PORTING.md).
 *
 * A tagged union's discriminant is a number, not a string, so the
 * 70-odd tests of `node.k` a self-compile makes are integer compares.
 * These constants are the numbers; KTAGS is the same list in the same
 * order for the places a tag reaches a diagnostic, and tags_agree()
 * checks the two. Numbers are positions in one alphabetical list, so a
 * new tag goes at the end and no existing number moves. */
#ifndef TAGS_H
#define TAGS_H

#include "yv.h"

Yv *ktag(long n);    /* the name of a tag, for a diagnostic */
int tags_agree(void); /* K and KTAGS have not drifted */

/* How deep the recursive walks may nest (MAX_NEST in src/y/tags.y, and
 * max_nest_agree() checks the two copies hold the same). A walk's entry
 * counts it and its one return path counts it back -- the count and the test
 * are written out there, per node, rather than called. */
#define MAX_NEST 1000
extern long yv_nest;   /* `nest`: a top-level long in src/y/tags.y */
Yv *too_deep(Yv *what, Yv *line, Yv *col);
Yv *nest_reset(void);
int max_nest_agree(void);

enum {
    K_a              = 1,
    K_addr           = 2,
    K_array          = 3,
    K_arrrep         = 4,
    K_assign         = 5,
    K_bad            = 6,
    K_bin            = 7,
    K_block          = 8,
    K_bool           = 9,
    K_bstr           = 10,
    K_call           = 11,
    K_char           = 12,
    K_decl           = 13,
    K_deref          = 14,
    K_diff           = 15,
    K_dot            = 16,
    K_dotassign      = 17,
    K_err            = 18,
    K_file           = 19,
    K_kw_for         = 20,
    K_kw_foreach     = 21,
    K_forrange       = 22,
    K_fs             = 23,
    K_func           = 24,
    K_git            = 25,
    K_h              = 26,
    K_id             = 27,
    K_idxassign      = 28,
    K_kw_if          = 29,
    K_imm            = 30,
    K_incdec         = 31,
    K_ind            = 32,
    K_index          = 33,
    K_kw             = 34,
    K_lbl            = 35,
    K_loc            = 36,
    K_map            = 37,
    K_matchend       = 38,
    K_mem            = 39,
    K_narrow         = 40,
    K_num            = 41,
    K_opassign       = 42,
    K_optarg         = 43,
    K_path           = 44,
    K_rec            = 45,
    K_rectest        = 46,
    K_reg            = 47,
    K_ret            = 48,
    K_rev            = 49,
    K_s              = 50,
    K_slice          = 51,
    K_sliceassign    = 52,
    K_store          = 53,
    K_str            = 54,
    K_t              = 55,
    K_tarr           = 56,
    K_tarrfix        = 57,
    K_tbool          = 58,
    K_tbyte          = 59,
    K_terr           = 60,
    K_tfloat         = 61,
    K_tfunc          = 62,
    K_tinfer         = 63,
    K_tlong          = 64,
    K_tmap           = 65,
    K_tname          = 66,
    K_tnone          = 67,
    K_topt           = 68,
    K_tparams        = 69,
    K_tpat           = 70,
    K_tpend          = 71,
    K_tptr           = 72,
    K_trec           = 73,
    K_tref           = 74,
    K_tstr           = 75,
    K_tunion         = 76,
    K_tunk           = 77,
    K_tvoid          = 78,
    K_typedef        = 79,
    K_un             = 80,
    K_void           = 81,
    K_kw_while       = 82,
};

#endif
