/* ── label identities ────────────────────────────────────────────────────
 * A label is a long: an index into `lbl_names`, the one place a label's name
 * exists. `lbl_new` mints one, `lname` reads the name back for the places that
 * still want text -- the emitted line (asm.y still lexes it), -S, -g's symbol
 * table, the pack and a diagnostic.
 *
 * Why it is an integer (OPTIMIZE.md Part 4 stage 1): a label's identity is
 * compared, not spelled. `e.label == st.self_label` decides whether a call is
 * a self-call, `namemap` decides whether a body is reachable, and the
 * assembler's labmap resolves every fixup -- all of that wants a number, and
 * today it pays for a string compare (or, once the emitter holds an operand
 * IR, for a name built at every use). With the name built once per site
 * instead, minting a label is an append to one array.
 *
 * One id per NAME, not per mint: the assembler resolves a label by name, so
 * two labels called `yfn_3_via_return$2` are one label, and every comparison
 * of two ids has to say so. A def's id is minted once -- compile_unit, where it
 * binds the def's env entry -- and handed to the hoisted table and to the body
 * (emit_one_fn); a plain counter would give those two a different number for
 * the same name, and is_self_call, which compares a callee's id with the
 * body's, would call a self-call an ordinary call: the tail call quietly
 * becomes a call and the frame grows per level.
 *
 * The table is per process and never reset: a name's id only has to agree with
 * itself, and a unit compiled from the pack has names, not ids (see Unit). */

#include "labels.h"
#include "asm.h"

static Yv *lbl_names;
static Yv *lbl_ix;
static long lbl_next;

/* Re-index every name at four times the old size. labmap_put does not grow (a
 * full table drops entries), so the caller refills before it is three quarters
 * full. It starts at 64, not at a size that fits the compiler: labmap_new
 * builds one record per slot, so a table sized for ycc.y costs every small
 * compile 1,024 of them (measured: +1.5% of a hello.y compile, half the cost
 * of stage 1). */
static void lbl_reindex(long cap) {
    Yv *m = labmap_new(cap);
    long i = 0;
    while (i < yv_len(lbl_names)) {
        Yv *r = labmap_put(m, ya_get(lbl_names, i), 1, i);
        m = yr_get(r, "map");
        i = i + 1;
    }
    lbl_ix = m;
}

Yv *lbl_new(Yv *name) {
    if (yv_len(lbl_ix) == 0) {
        lbl_reindex(64);
    } else {
        if (4 * (lbl_next + 1) > 3 * yv_len(lbl_ix)) {
            lbl_reindex(4 * yv_len(lbl_ix) + 64);
        }
    }
    Yv *g = labmap_get(lbl_ix, name);
    if (yv_l(yr_get(g, "sec")) >= 0) {
        return yr_get(g, "off");
    } else {
        Yv *r = labmap_put(lbl_ix, name, 1, lbl_next);
        lbl_ix = yr_get(r, "map");
        long id = lbl_next;
        lbl_names = ya_push(lbl_names, name);
        lbl_next = lbl_next + 1;
        return yv_long(id);
    }
}

/* A label no one else can name: a local (`yL_<fuid>_<n>`, and the fuid is
 * unique per body), which is 20,052 of the 26,000 labels a self-compile
 * mints. It needs no interning -- the name is built once and never asked for
 * again -- so it skips the table (measured: interning every label costs
 * +1.9% of a compile; skipping the locals' share of it is most of that). */
Yv *lbl_fresh(Yv *name) {
    long id = lbl_next;
    lbl_names = ya_push(lbl_names, name);
    lbl_next = lbl_next + 1;
    return yv_long(id);
}

/* The name of a label; "" for -1, which is what a slot with no label (a local,
 * a mark) carries. */
Yv *lname(Yv *id) {
    long i = yv_l(id);
    if (i < 0) { return ys(""); } else { return ya_get(lbl_names, i); }
}