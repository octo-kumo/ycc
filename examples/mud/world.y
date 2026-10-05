// world.y -- the world: rooms, exits, items, monsters.  All of it derived from
// one seed, and none of it mutable after generate().
//
// ===========================================================================
// WHY A LATTICE AND NOT A CARVED DUNGEON MAP
// ===========================================================================
//
// A roguelike carves rooms into a tile grid and then has to *discover* the room
// graph by flood-filling corridors.  That step is the interesting part of that
// generator and it is also where the awkward properties live: two corridors
// that cross can merge two rooms into one, a corridor can leave a room through
// a wall, and the exit directions are whatever the geometry happened to be.
//
// Here the graph IS the map.  A room is a cell of a 7x5 lattice; an exit is a
// direction.  Three properties then hold by construction rather than by luck,
// and property check (a) in props.y re-proves all three over the built graph:
//
//   1. CONNECTED.  A new room is only ever placed in a lattice cell that is
//      lattice-ADJACENT to an already-placed room, and the edge to that parent
//      is added at the moment of placement.  So the edge set always contains a
//      spanning tree over the rooms, grown one room at a time.
//   2. TWO-WAY.  An edge from a to b in direction d adds the reverse edge from b
//      to a in opposite(d) in the SAME statement that adds the first.  There is
//      no code path that adds one without the other.
//   3. NO DIRECTION CLASH.  Because an edge is only ever a lattice step, the
//      direction from a to b is unique: a's north neighbour is exactly the
//      lattice cell one row up, and there is only one room there.  A room can
//      therefore have all four exits, with no ambiguity about which is which --
//      which a carved map cannot promise.
//
// The extra edges added afterwards (the "loops") go through the same
// add_edge_pair(), so they are two-way too, and a loop can never make a room
// have two norths: add_edge_pair() checks that both ends are free first.
//
// ===========================================================================
// WHY PARALLEL ARRAYS AND NOT A MAP OF RECORDS
// ===========================================================================
//
// Same reason as everywhere else in this campaign (ORCHESTRATOR.md 2.8): a map
// in Y is a linear scan, and `look` asks "what is in this room" for every item
// instance.  With parallel arrays that is one indexed load.  And records held
// in a union would be a heap allocation per access (40 bytes measured), which
// in a per-command path is a leak; a `long` is not.
//
// The arrays are built ONCE, in generate(), with `+=`.  Nothing here allocates
// after that: a room lookup is always arithmetic.

// ---- the limits, all compile-time (a fixed array size must be a literal) ---
const MAXR = 24;          // rooms in the world
const MAXI = 72;          // item instances (3 per room)
const MAXK = 8;           // item kinds
const MAXM = 4;           // monster kinds
const LATW = 7;           // lattice width
const LATH = 5;           // lattice height
const LATN = 35;          // LATW * LATH

// directions: 0 north, 1 east, 2 south, 3 west
const D_N = 0;
const D_E = 1;
const D_S = 2;
const D_W = 3;

let DIRNAME: [str] = ["north", "east", "south", "west"];
let DIRABBR: [str] = ["n", "e", "s", "w"];
let OPPOSITE: [long] = [2, 3, 0, 1];
let DX: [long] = [0, 1, 0, 0 - 1];
let DY: [long] = [0 - 1, 0, 1, 0];

// ---- the immutable world --------------------------------------------------
let R_NAME: [str] = [];
let R_DESC: [str] = [];
let R_LX: [long] = [];        // lattice column
let R_LY: [long] = [];        // lattice row
let EX_TO: [long] = [];       // MAXR * 4, flat; -1 = no exit
let EX_DIR: [long] = [];      // MAXR * 4, flat; the direction code, or -1
let EX_N: [long] = [];        // per room, how many exits
let I_ROOM: [long] = [];      // item instance -> the room it starts in
let I_ID: [long] = [];        // item instance -> kind
let I_QTY: [long] = [];       // item instance -> how many
let M_KIND: [long] = [];      // room -> monster kind, or -1
let M_HP: [long] = [];        // room -> monster hit points at birth
let NROOMS: [long] = [0];
let NEXITS: [long] = [0];
let NINST: [long] = [0];
let SEED: [long] = [0];

// ---- the word tables ------------------------------------------------------
let ADJ: [str] = [
    "cold", "wide", "sunken", "echoing",
    "gilded", "drowned", "narrow", "flooded"
];
let NOUN: [str] = [
    "hall", "vault", "cistern", "gallery",
    "stairwell", "shrine", "tunnel", "courtyard"
];
let LIGHT: [str] = [
    "guttering torches", "a shaft of pale daylight",
    "phosphorescent moss", "nothing you can see"
];
let IT_NAME: [str] = [
    "brass torch", "silver coin", "iron key", "clay vial",
    "rusted dagger", "torn scroll", "leather pouch", "bone charm"
];
let IT_WITH: [str] = [
    "a brass torch", "a silver coin", "an iron key", "a clay vial",
    "a rusted dagger", "a torn scroll", "a leather pouch", "a bone charm"
];
let IT_W: [long] = [4, 1, 1, 3, 5, 2, 2, 1];      // value in coins
let MO_NAME: [str] = ["cave rat", "giant bat", "moss troll", "shadow hound"];
let MO_HP0: [long] = [4, 7, 14, 19];
let MO_ATK: [long] = [2, 3, 4, 5];

// ---------------------------------------------------------------------------
// generation
// ---------------------------------------------------------------------------

def clear_all() -> long {
    R_NAME = []; R_DESC = []; R_LX = []; R_LY = [];
    EX_TO = []; EX_DIR = []; EX_N = [];
    I_ROOM = []; I_ID = []; I_QTY = [];
    M_KIND = []; M_HP = [];
    NROOMS[0] = 0; NEXITS[0] = 0; NINST[0] = 0;
    0
};

// "a"/"an" -- the only vowel test in the program, and it is a byte compare
// because Y has no character literals (ORCHESTRATOR.md 2.10: 'a' is a lexer
// error; ord("a") is the way).
def article(w: str) -> str {
    let c = w[0];
    if (c == 97 || c == 101 || c == 105 || c == 111 || c == 117) { "an" } else { "a" }
};

def room_text(i: long, adj: long, noun: long, light: long) -> long {
    let a = ADJ[adj];
    let n = NOUN[noun];
    R_NAME += a + " " + n;
    // Every noun here is singular, so the plural is a plain +s.
    R_DESC += "A " + article(a) + " " + a + " " + n + " of " + LIGHT[light] + ".";
    R_LX += 0;
    R_LY += 0;
    EX_TO += [0 - 1; 4];
    EX_DIR += [0 - 1; 4];
    EX_N += 0;
    M_KIND += 0 - 1;
    M_HP += 0;
    i
};

def place_room(x: long, y: long) -> long {
    let i = len(R_NAME);
    room_text(i, rnd.rnd_below(8), rnd.rnd_below(8), rnd.rnd_below(4));
    R_LX[i] = x;
    R_LY[i] = y;
    NROOMS[0] = NROOMS[0] + 1;
    i
};

// add_edge_pair(a, d, b): a gets an exit in direction d to b, and b gets the
// exact reverse in opposite(d).  Both halves live here, which is what makes the
// two-way property true by construction rather than by convention.  It refuses
// (returns 0 without touching anything) when either end already has that exit,
// so a "loop" edge can never give a room two norths.
def add_edge_pair(a: long, d: long, b: long) -> long {
    let od = OPPOSITE[d];
    if (d < 0 || d > 3 || od < 0 || od > 3) { 0 } else {
        if (EX_TO[a * 4 + d] >= 0 || EX_TO[b * 4 + od] >= 0) { 0 } else {
            EX_TO[a * 4 + d] = b;
            EX_DIR[a * 4 + d] = d;
            EX_TO[b * 4 + od] = a;
            EX_DIR[b * 4 + od] = od;
            EX_N[a] = EX_N[a] + 1;
            EX_N[b] = EX_N[b] + 1;
            NEXITS[0] = NEXITS[0] + 2;
            1
        }
    }
};

// Does room a already have an edge to room b?
def linked(a: long, b: long) -> bool {
    let d = 0;
    let found = false;
    while (d < 4) {
        if (EX_TO[a * 4 + d] == b) { found = true };
        d = d + 1;
    };
    found
};

def generate(seed: long) -> long {
    clear_all();
    SEED[0] = seed;
    rnd.rnd_seed(seed);
    let occ: [long; 35] = [0; 35];         // lattice cell -> room + 1, else 0
    let target = 16 + rnd.rnd_below(9);               // 16..24 rooms

    let start = place_room(0, 0);
    occ[0] = start + 1;

    // ---- grow, one lattice step at a time.  Every room but the first arrives
    // with its edge to its parent already made, so the edge set always has a
    // spanning tree.
    let attempts = 0;
    let live = true;
    while (live && len(R_NAME) < target && attempts < 900) {
        attempts = attempts + 1;
        let r = rnd.rnd_below(len(R_NAME));
        let d = rnd.rnd_below(4);
        let nx = R_LX[r] + DX[d];
        let ny = R_LY[r] + DY[d];
        let ok = nx >= 0 && nx < LATW && ny >= 0 && ny < LATH;
        if (ok) {
            ok = occ[ny * LATW + nx] == 0;
        };
        if (ok) {
            let nr = place_room(nx, ny);
            occ[ny * LATW + nx] = nr + 1;
            add_edge_pair(r, d, nr);
        }
    };

    // ---- loops: for every lattice-adjacent pair not already joined, join it
    // one time in four.  This is what gives the world shortcuts and cycles, so
    // a BFS distance is not a tree depth.
    let a = 0;
    let pass = true;
    while (a < len(R_NAME) && pass) {
        let d = 0;
        let inner = true;
        while (d < 4 && inner) {
            let nx = R_LX[a] + DX[d];
            let ny = R_LY[a] + DY[d];
            let near = nx >= 0 && nx < LATW && ny >= 0 && ny < LATH;
            if (near) {
                let b = occ[ny * LATW + nx] - 1;
                if (b >= 0 && b != a && !linked(a, b)) {
                    if (rnd.rnd_below(4) == 0) { add_edge_pair(a, d, b); };
                };
            };
            d = d + 1;
        };
        a = a + 1;
    };

    // ---- stock the rooms.  The start room always has a torch and a coin, so
    // the documented deterministic run always exercises take and drop, and
    // always has a monster, so wait and attack do something visible.
    let i = 0;
    while (i < len(R_NAME)) {
        let k = 0;
        let want = rnd.rnd_below(4);                       // 0..3 items
        while (k < want && len(I_ROOM) < MAXI) {
            let id = rnd.rnd_below(MAXK);
            let qty = 1 + rnd.rnd_below(3);
            I_ROOM += i;
            I_ID += id;
            I_QTY += qty;
            k = k + 1;
        };
        i = i + 1;
    };
    if (len(I_ROOM) < 2) {
        I_ROOM += 0; I_ID += 0; I_QTY += 1;
        I_ROOM += 0; I_ID += 1; I_QTY += 2;
    };
    if (len(I_ROOM) < MAXI) {
        I_ROOM += 0; I_ID += 0; I_QTY += 1;      // the guaranteed brass torch
        I_ROOM += 0; I_ID += 1; I_QTY += 3;      // the guaranteed silver coins
    };
    NINST[0] = len(I_ROOM);

    let m = 0;
    while (m < len(R_NAME)) {
        if (m == 0 || rnd.rnd_below(4) == 0) {
            let kind = rnd.rnd_below(MAXM);
            M_KIND[m] = kind;
            M_HP[m] = MO_HP0[kind] + rnd.rnd_below(4);
        } else {
            M_KIND[m] = 0 - 1;
            M_HP[m] = 0;
        };
        m = m + 1;
    };
    len(R_NAME)
};

// ---------------------------------------------------------------------------
// accessors
// ---------------------------------------------------------------------------

def rooms() -> long { len(R_NAME) };
def exits_total() -> long { NEXITS[0] };
def insts() -> long { len(I_ROOM) };
def name(r: long) -> str { R_NAME[r] };
def desc(r: long) -> str { R_DESC[r] };
def ex_to(r: long, d: long) -> long { EX_TO[r * 4 + d] };
def ex_dir(r: long, d: long) -> long { EX_DIR[r * 4 + d] };
def ex_n(r: long) -> long { EX_N[r] };
def i_room(i: long) -> long { I_ROOM[i] };
def i_id(i: long) -> long { I_ID[i] };
def i_qty(i: long) -> long { I_QTY[i] };
def m_kind(r: long) -> long { M_KIND[r] };
def m_hp(r: long) -> long { M_HP[r] };
def item_name(id: long) -> str { IT_NAME[id] };
def item_with(id: long) -> str { IT_WITH[id] };
def item_value(id: long) -> long { IT_W[id] };
def mon_name(k: long) -> str { MO_NAME[k] };
def mon_atk(k: long) -> long { MO_ATK[k] };
def dir_name(d: long) -> str { DIRNAME[d] };
def dir_abbr(d: long) -> str { DIRABBR[d] };
def lx(r: long) -> long { R_LX[r] };
def ly(r: long) -> long { R_LY[r] };

// "north" | "n" -> 0..3, or -1
def dir_of(s: str) -> long {
    let d = 0;
    let hit = 0 - 1;
    while (d < 4) {
        if (s == DIRNAME[d] || s == DIRABBR[d]) { hit = d };
        d = d + 1;
    };
    hit
};

// ---------------------------------------------------------------------------
// property check (a): reachability and two-way exits, by BFS over the graph
// that was actually built -- not over the intent that built it.
// ---------------------------------------------------------------------------

let BFSQ: [long; 24] = [0; 24];
let BFSD: [long; 24] = [0; 24];

// Shortest distance from the start room to every room, -1 when unreachable.
def bfs(start: long) -> long {
    let i = 0;
    while (i < len(R_NAME)) { BFSD[i] = 0 - 1; i = i + 1; };
    let head = 0;
    let tail = 0;
    BFSD[start] = 0;
    BFSQ[tail] = start;
    tail = tail + 1;
    while (head < tail) {
        let r = BFSQ[head];
        head = head + 1;
        let d = 0;
        while (d < 4) {
            let t = EX_TO[r * 4 + d];
            if (t >= 0 && BFSD[t] < 0) {
                BFSD[t] = BFSD[r] + 1;
                BFSQ[tail] = t;
                tail = tail + 1;
            };
            d = d + 1;
        };
    };
    tail - 1
};

def dist_to(r: long) -> long { BFSD[r] };

def unreachable() -> long {
    bfs(0);
    let i = 0;
    let n = 0;
    while (i < len(R_NAME)) {
        if (BFSD[i] < 0) { n = n + 1 };
        i = i + 1;
    };
    n
};

// Every exit a -> b in direction d must be matched by b -> a in opposite(d).
def one_way() -> long {
    let n = 0;
    let r = 0;
    while (r < len(R_NAME)) {
        let d = 0;
        while (d < 4) {
            let t = EX_TO[r * 4 + d];
            if (t >= 0) {
                if (EX_TO[t * 4 + OPPOSITE[d]] != r) { n = n + 1 };
            };
            d = d + 1;
        };
        r = r + 1;
    };
    n
};

// A direction d of room r must be a single exit, never a duplicate: two exits
// in the same direction would make the map ambiguous, and the renderer prints
// the direction list, so a duplicate would be visible in the transcript too.
def dup_dirs() -> long {
    let n = 0;
    let r = 0;
    while (r < len(R_NAME)) {
        let a = 0;
        while (a < 4) {
            let b = a + 1;
            while (b < 4) {
                if (EX_TO[r * 4 + a] >= 0 && EX_TO[r * 4 + b] >= 0) {
                    if (EX_TO[r * 4 + a] == EX_TO[r * 4 + b]) { n = n + 1 };
                };
                b = b + 1;
            };
            a = a + 1;
        };
        r = r + 1;
    };
    n
};