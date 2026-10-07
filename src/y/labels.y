// ── label identities ────────────────────────────────────────────────────
// A label is a long: an index into `lbl_names`, the one place a label's name
// exists. `lbl_new` mints one, `lname` reads the name back for the places that
// still want text -- the emitted line (asm.y still lexes it), -S, -g's symbol
// table, the pack and a diagnostic.
//
// Why it is an integer (OPTIMIZE.md Part 4 stage 1): a label's identity is
// compared, not spelled. `e.label == st.self_label` decides whether a call is
// a self-call, `namemap` decides whether a body is reachable, and the
// assembler's labmap resolves every fixup -- all of that wants a number, and
// today it pays for a string compare (or, once the emitter holds an operand
// IR, for a name built at every use). With the name built once per site
// instead, minting a label is an append to one array.
//
// One id per NAME, not per mint: the assembler resolves a label by name, so
// two labels called `yfn_3_via_return$2` are one label, and every comparison
// of two ids has to say so. A def's id is minted once -- compile_unit, where it
// binds the def's env entry -- and handed to the hoisted table and to the body
// (emit_one_fn); a plain counter would give those two a different number for
// the same name, and is_self_call, which compares a callee's id with the
// body's, would call a self-call an ordinary call: the tail call quietly
// becomes a call and the frame grows per level.
//
// The table is per process and never reset: a name's id only has to agree with
// itself, and a unit compiled from the pack has names, not ids (see Unit).
import asm from "./asm.y";

let lbl_names: [str] = [];
let lbl_ix: [AsmLabel] = [];
let lbl_next = 0;

// Re-index every name at four times the old size. labmap_put does not grow (a
// full table drops entries), so the caller refills before it is three quarters
// full. It starts at 64, not at a size that fits the compiler: labmap_new
// builds one record per slot, so a table sized for ycc.y costs every small
// compile 1,024 of them (measured: +1.5% of a hello.y compile, half the cost
// of stage 1).
def lbl_reindex(cap: long) {
    let m = asm.labmap_new(cap);
    let i = 0;
    while (i < len(lbl_names)) {
        let r = asm.labmap_put(m, lbl_names[i], 1, i);
        m = r.map;
        i++;
    };
    lbl_ix = m
};

def lbl_new(name: str) -> long {
    if (len(lbl_ix) == 0) { lbl_reindex(64); }
    else { if (4 * (lbl_next + 1) > 3 * len(lbl_ix)) { lbl_reindex(4 * len(lbl_ix) + 64); }; };
    let g = asm.labmap_get(lbl_ix, name);
    if (g.sec >= 0) {
        g.off
    } else {
        let r = asm.labmap_put(lbl_ix, name, 1, lbl_next);
        lbl_ix = r.map;
        let id = lbl_next;
        lbl_names += name;
        lbl_next++;
        id
    }
};

// A label no one else can name: a local (`yL_<fuid>_<n>`, and the fuid is
// unique per body), which is 20,052 of the 26,000 labels a self-compile
// mints. It needs no interning -- the name is built once and never asked for
// again -- so it skips the table (measured: interning every label costs
// +1.9% of a compile; skipping the locals' share of it is most of that).
def lbl_fresh(name: str) -> long {
    let id = lbl_next;
    lbl_names += name;
    lbl_next++;
    id
};

// The name of label `id`; "" for -1, which is what a slot with no label (a
// local, a mark) carries.
def lname(id: long) -> str {
    if (id < 0) { "" } else { lbl_names[id] }
};