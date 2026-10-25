// ── label identities ────────────────────────────────────────────────────
import asm from "./asm.y";

let lbl_names: [str] = [];
let lbl_ix: [AsmLabel] = [];
let lbl_next = 0;

def lbl_reindex(cap: long) -> void {
    let m = asm.labmap_new(cap);
    lbl_names.foreach((e, i) => {
        m = (asm.labmap_put(m, e, 1, i)).map;
    });
    lbl_ix = m
};

def lbl_new(name: str) -> long {
    if (len(lbl_ix) == 0) { lbl_reindex(64); }
    else { if (4 * (lbl_next + 1) > 3 * len(lbl_ix)) { lbl_reindex(4 * len(lbl_ix) + 64); }; };
    let g = asm.labmap_get(lbl_ix, name);
    if (g.sec >= 0) {
        g.off
    } else {
        lbl_ix = (asm.labmap_put(lbl_ix, name, 1, lbl_next)).map;
        let id = lbl_next;
        lbl_names += name;
        lbl_next++;
        id
    }
};

// Local labels are unique already and need no name interning.
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
