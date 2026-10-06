// store.y -- the in-memory resource collection behind the REST server.
//
//   import store;
//
//   let id = store.take("milk", 2);      // 201's new id
//   let at = store.find(1);              // a slot index, -1 if absent
//   store.put(1, "oat milk", 4);         // 200's update
//   store.drop(1);                       // 204
//   store.live();                        // how many are there now
//
// Pure data: no syscalls, no allocation, no I/O. Keeping the collection
// out of the socket code means the state machine the property check
// asserts about is the same one the HTTP layer hands out, and it can also
// be exercised without a server at all (--self-test does both).
//
// ── why parallel fixed arrays and not an array of records ────────────
//
// The arena never frees, so a `[Item]` that grows would leak its old
// header; fixed `[long; 16]`s at module level are allocated once and
// reused for the life of the process. A slot with id 0 is free -- ids
// start at 1 -- so no separate `alive` flag is needed. 16 slots is a
// deliberate limit: it is a resource *collection*, not a database, and a
// bounded one is what lets the server answer every request from memory
// with no allocation at all.
//
// `order()` is why a fixed table is not a flat array to a client: ids are
// handed out in order but a delete punches a hole in the middle, so the
// listing walks live slots in ascending id rather than slot order.

const MAX = 16;               // slots; a create past this is 507

let s_id: [long; 16] = [0; 16];
let s_title: [str; 16] = ["", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""];
let s_qty: [long; 16] = [0; 16];
let s_done: [bool; 16] = [false, false, false, false, false, false, false, false,
                          false, false, false, false, false, false, false, false];

// how many resources have ever been created (the id counter is one past
// the highest), and how many are live now
let s_next = 1;
let s_live = 0;

// counters the property check reads: they are the server's own account of
// what it did, which is a *second* opinion next to the client's
let s_created = 0;
let s_updated = 0;
let s_deleted = 0;
let s_rejected = 0;           // a create refused as a duplicate (409)

// empty the collection and start handing out ids at 1 again
def reset() {
    let i = 0;
    while (i < MAX) {
        s_id[i] = 0;
        s_title[i] = "";
        s_qty[i] = 0;
        s_done[i] = false;
        i = i + 1;
    };
    s_next = 1;
    s_live = 0;
    s_created = 0;
    s_updated = 0;
    s_deleted = 0;
    s_rejected = 0;
};

// the slot holding `id`, or -1
def find(id: long) -> long {
    let i = 0;
    let out = -1;
    while (i < MAX && out < 0) {
        if (s_id[i] == id && id > 0) { out = i; };
        i = i + 1;
    };
    out
};

def live() -> long { s_live };
def next_id() -> long { s_next };
def created() -> long { s_created };
def updated() -> long { s_updated };
def deleted() -> long { s_deleted };
def rejected() -> long { s_rejected };
def full() -> bool { s_live >= MAX };

def title_of(id: long) -> str {
    let at = find(id);
    if (at < 0) { "" } else { s_title[at] }
};

def qty_of(id: long) -> long {
    let at = find(id);
    if (at < 0) { 0 - 1 } else { s_qty[at] }
};

def done_of(id: long) -> bool {
    let at = find(id);
    if (at < 0) { false } else { s_done[at] }
};

def set_done(id: long, v: bool) -> bool {
    let at = find(id);
    if (at < 0) { return false; };
    s_done[at] = v;
    true
};

// The slot of the `want`-th live resource in ascending id order, -1 if
// there is no such one. This is the order a listing uses, so it is a
// property of the *collection* rather than of the table's holes.
def order(want: long) -> long {
    let seen = 0;
    let id = 1;
    let out = -1;
    while (id < s_next && out < 0) {
        let at = find(id);
        if (at >= 0) {
            if (seen == want) { out = at; } else { seen = seen + 1; };
        };
        id = id + 1;
    };
    out
};

// Create with a server-assigned id. The id comes back; -1 when the table
// is full (the server answers 507 for that).
def take(title: str, qty: long) -> long {
    if (full()) { return 0 - 1; };
    let id = s_next;
    s_next = id + 1;
    let at = find(id);
    if (at < 0) { at = free_slot() };
    s_id[at] = id;
    s_title[at] = title;
    s_qty[at] = qty;
    s_done[at] = false;
    s_live = s_live + 1;
    s_created = s_created + 1;
    id
};

// Create with a caller's id: 409's shape. Returns the id, or -1 because
// that id is taken, or 0 -2 because it is not a legal id (> 0).
def take_id(id: long, title: str, qty: long) -> long {
    if (id <= 0) { return 0 - 2; };
    if (find(id) >= 0) { s_rejected = s_rejected + 1; return 0 - 1; };
    if (full()) { return 0 - 1; };
    // the counter only ever moves up: a create with a low id must not
    // hand out that id again to the next server-assigned create
    if (id >= s_next) { s_next = id + 1; };
    let at = free_slot();
    s_id[at] = id;
    s_title[at] = title;
    s_qty[at] = qty;
    s_done[at] = false;
    s_live = s_live + 1;
    s_created = s_created + 1;
    id
};

// the first free slot, or -1 (which take() has already ruled out)
def free_slot() -> long {
    let i = 0;
    let out = -1;
    while (i < MAX && out < 0) {
        if (s_id[i] == 0) { out = i; };
        i = i + 1;
    };
    out
};

// Update in place: the id, or -1 because there is no such resource
def put(id: long, title: str, qty: long) -> long {
    let at = find(id);
    if (at < 0) { return 0 - 1; };
    s_title[at] = title;
    s_qty[at] = qty;
    s_updated = s_updated + 1;
    id
};

// Delete: true when it was there
def drop(id: long) -> bool {
    let at = find(id);
    if (at < 0) { return false; };
    s_id[at] = 0;
    s_title[at] = "";
    s_qty[at] = 0;
    s_done[at] = false;
    s_live = s_live - 1;
    s_deleted = s_deleted + 1;
    true
};

// The sum of every live qty -- a derived number a check can compare with
// its own arithmetic without asking the store anything.
def total() -> long {
    let t = 0;
    let i = 0;
    while (i < MAX) {
        if (s_id[i] > 0) { t = t + s_qty[i]; };
        i = i + 1;
    };
    t
};

export {
    MAX, s_id, s_title, s_qty, s_done,
    reset, find, live, next_id, created, updated, deleted, rejected, full,
    title_of, qty_of, done_of, set_done, order, take, take_id, free_slot,
    put, drop, total
};
