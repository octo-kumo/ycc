// rules.y -- what a thing IS: the two record unions (a tile, an item) and the
// monster table.
//
// ===========================================================================
// WHY UNIONS AT ALL, AND WHERE THEY ARE ALLOWED TO RUN
// ===========================================================================
//
// A tile and an item are the natural use of a union in Y:
//
//     type Terrain = Rock | Floor | Door | Stairs;
//     type Loot    = Gold | Potion | Scroll | Dagger;
//
// and `match` is the natural way to read one.  Two things about the language
// shape how they are used here, and both are worth stating because both cost
// an afternoon if you find them the hard way:
//
//   1. A `match` WHOSE ARMS ARE RECORDS CANNOT BE A BLOCK'S VALUE.  With `Loot`
//      as the declared return type,
//          def pick(l: Loot) -> Loot { match l { Gold g => ..., Potion p => ... } }
//      is a hard error: `error: 'pick' body: expected {...} | {...}, got void`.
//      The same match with `str` arms, or with `long` arms, is fine, and so is
//      a match whose arms are values ALREADY typed as the union.  So every
//      `match` here RETURNS A SCALAR (a `str` name, a `long` number), never a
//      record: the union is read, never rebuilt.  Building one is
//      `let l: Loot = { tag: ..., heal: ... };` in an annotated position, which
//      works.
//   2. A `match` ARM BINDING COPIES, A DESTRUCTURING PATTERN READS IN PLACE.
//      `Potion p => ...` copies the member record out of the union before `p`
//      is bound; `Potion { heal } => ...` reads `heal` where it lies.  Both are
//      correct for a read, so this file uses the destructuring form wherever one
//      field is wanted (it says exactly which field it wants, and it is the form
//      that does not copy) and a binding only where the whole record is wanted.
//
// AND WHERE THEY RUN.  Every call into here is on a COLD path: a level is built
// once, an item is named when it is picked up, a message is rendered when it is
// logged.  A union value is a heap record -- 40 bytes measured, SUGGESTIONS.md
// 7 -- and the heap is an arena, so a union consulted once per tile per frame
// would leak 80 KB a frame.  That is why the frame path (fov.y, view.y) works
// on plain `long` codes and only comes here for a name.

import rnd;
import tui;

// ---------------------------------------------------------------------------
// the tile union
// ---------------------------------------------------------------------------

const T_WALL = 0;
const T_FLOOR = 1;
const T_DOOR = 2;
const T_STAIRS = 3;
const TERRAIN_CODES = 4;

type Rock = { tag: long };
type Floor = { tag: long, wear: long };
type Door = { tag: long, open: bool };
type Stairs = { tag: long, down: long };
type Terrain = Rock | Floor | Door | Stairs;

// The four terrains, built ONCE into a fixed [Terrain; 4] and handed out by
// index.  Building a union value is the only place a record literal appears in
// this file, and it happens four times at module load, not per call.
// NOTE THE NAMES.  The four union VALUES are U_ROCK..U_STAIRS, not T_ROCK: a
// module cannot have both a `const T_WALL = 0` and a `let T_WALL: Terrain`, and
// the record wins -- after which `rules.T_STAIRS` is a union and
// `tile_at(x, y) == rules.T_STAIRS` is a hard error.  The U_ prefix keeps the
// two apart.
let U_ROCK: Terrain = { tag: T_WALL };
let U_FLOOR: Terrain = { tag: T_FLOOR, wear: 0 };
let U_DOOR: Terrain = { tag: T_DOOR, open: false };
let U_STAIRS: Terrain = { tag: T_STAIRS, down: 1 };
let TERRAIN: [Terrain; 4] = [U_ROCK, U_FLOOR, U_DOOR, U_STAIRS];

// terrain_at(code) -> Terrain -- the one union-valued function here.  Safe for
// any code, because the argument is clamped into the table.
def terrain_at(code: long) -> Terrain {
    let c = code;
    if (c < 0) { c = 0; };
    if (c > TERRAIN_CODES - 1) { c = TERRAIN_CODES - 1; };
    TERRAIN[c]
};

// terrain_tag(t) -> long -- a `match` returning a plain long, which IS allowed
// to be a block's value.
def terrain_tag(t: Terrain) -> long {
    match t {
        Rock { tag } => tag,
        Floor { tag } => tag,
        Door { tag } => tag,
        Stairs { tag } => tag
    }
};

// terrain_name(t) -> str -- and a `match` returning a str.  A destructuring
// pattern wherever one field does the job, so the arm says which field it wants.
def terrain_name(t: Terrain) -> str {
    match t {
        Rock _ => "granite",
        Floor { wear } => if (wear == 0) { "flagstone" } else { "worn flagstone" },
        Door { open } => if (open) { "oak door" } else { "oak door, shut" },
        Stairs { down } => "stairway down to " + tostring(down)
    }
};

def terrain_glyph(t: Terrain) -> long {
    match t {
        Rock _ => 35,                  // '#'
        Floor _ => 46,                 // '.'
        Door { open } => if (open) { 43 } else { 43 },   // '+'
        Stairs _ => 62                 // '>'
    }
};

// ---------------------------------------------------------------------------
// the item union
// ---------------------------------------------------------------------------

const K_GOLD = 0;
const K_POTION = 1;
const K_SCROLL = 2;
const K_DAGGER = 3;
const KINDS = 4;

type Gold = { tag: long };
type Potion = { tag: long, heal: long };
type Scroll = { tag: long, reveal: long };
type Dagger = { tag: long, dmg: long };
type Loot = Gold | Potion | Scroll | Dagger;

let L_GOLD: Loot = { tag: K_GOLD };
let L_POTION: Loot = { tag: K_POTION, heal: 12 };
let L_SCROLL: Loot = { tag: K_SCROLL, reveal: 1 };
let L_DAGGER: Loot = { tag: K_DAGGER, dmg: 3 };

def make_gold() -> Loot { L_GOLD };
def make_potion(heal: long) -> Loot {
    let p: Potion = { tag: K_POTION, heal: heal };
    p
};
def make_scroll(reveal: long) -> Loot {
    let s: Scroll = { tag: K_SCROLL, reveal: reveal };
    s
};
def make_dagger(dmg: long) -> Loot {
    let d: Dagger = { tag: K_DAGGER, dmg: dmg };
    d
};

def loot_kind(l: Loot) -> long {
    match l {
        Gold { tag } => tag,
        Potion { tag } => tag,
        Scroll { tag } => tag,
        Dagger { tag } => tag
    }
};

def loot_name(l: Loot) -> str {
    match l {
        Gold _ => "gold",
        Potion { heal } => "potion of healing (" + tostring(heal) + ")",
        Scroll { reveal } => if (reveal == 1) { "scroll of mapping" } else { "scroll" },
        Dagger { dmg } => "dagger (" + tostring(dmg) + " to hit)"
    }
};

// loot_action -- what the use key does with it, as a code, because the turn
// logic would rather switch on a long than build a string.
const A_NOTHING = 0;
const A_HEAL = 1;
const A_REVEAL = 2;
const A_WIELD = 3;

def loot_action(l: Loot) -> long {
    match l {
        Gold _ => A_NOTHING,
        Potion _ => A_HEAL,
        Scroll _ => A_REVEAL,
        Dagger _ => A_WIELD
    }
};

def loot_heal(l: Loot) -> long {
    match l {
        Gold _ => 0,
        Potion { heal } => heal,
        Scroll _ => 0,
        Dagger _ => 0
    }
};

def loot_reveal(l: Loot) -> long {
    match l {
        Gold _ => 0,
        Potion _ => 0,
        Scroll { reveal } => reveal,
        Dagger _ => 0
    }
};

def loot_dmg(l: Loot) -> long {
    match l {
        Gold _ => 0,
        Potion _ => 0,
        Scroll _ => 0,
        Dagger { dmg } => dmg
    }
};

def loot_glyph(l: Loot) -> long {
    match l {
        Gold _ => 36,                  // '$'
        Potion _ => 33,                // '!'
        Scroll _ => 63,                // '?'
        Dagger _ => 47                 // '/'
    }
};

def loot_name_of_kind(k: long) -> str {
    let c = k;
    if (c < 0) { c = 0; };
    if (c > KINDS - 1) { c = KINDS - 1; };
    let l: Loot = L_GOLD;
    if (c == K_POTION) { l = L_POTION; }
    else if (c == K_SCROLL) { l = L_SCROLL; }
    else if (c == K_DAGGER) { l = L_DAGGER; };
    loot_name(l)
};

// ---------------------------------------------------------------------------
// monsters
// ---------------------------------------------------------------------------
//
// A table, not a union: five species with no per-instance fields beyond HP, and
// HP lives in the roster.  A union here would buy nothing and would put a heap
// record on the walk path.
//
// kind | hp | dmg | glyph | rgb          the rgb is the only colour in this file,
//  0   |  3 |  1 | 'r'   | (150,110, 90)  and it is here because a species
//  1   |  2 |  1 | 'b'   | (120, 90,140)  colour belongs to the species, not to
//  2   |  5 |  2 | 's'   | ( 90,150, 90)  the renderer.
//  3   |  9 |  3 | 'o'   | (190, 90, 80)
//  4   | 16 |  5 | 'T'   | (170, 60,170)

const M_RAT = 0;
const M_BAT = 1;
const M_SNAKE = 2;
const M_ORC = 3;
const M_TROLL = 4;
const M_KINDS = 5;
const M_HP: [long; 5] = [3, 2, 5, 9, 16];
const M_DMG: [long; 5] = [1, 1, 2, 3, 5];
const M_GLYPH: [long; 5] = [114, 98, 115, 111, 84];   // r b s o T
const M_NAME: [str; 5] = ["giant rat", "bat", "snake", "orc", "troll"];

// Every level deeper adds one point of damage to everything, so a depth-5 rat
// is not a depth-1 rat with more hit points.
const M_DEPTH_DMG = 1;

def monster_kind_name(k: long) -> str {
    let c = k;
    if (c < 0) { c = 0; };
    if (c > M_KINDS - 1) { c = M_KINDS - 1; };
    M_NAME[c]
};

def monster_glyph(k: long) -> long {
    let c = k;
    if (c < 0) { c = 0; };
    if (c > M_KINDS - 1) { c = M_KINDS - 1; };
    M_GLYPH[c]
};

def monster_colour(k: long) -> long {
    let c = k;
    if (c == M_RAT) { return tui.rgb(150, 110, 90); };
    if (c == M_BAT) { return tui.rgb(120, 90, 140); };
    if (c == M_SNAKE) { return tui.rgb(90, 150, 90); };
    if (c == M_ORC) { return tui.rgb(190, 90, 80); };
    tui.rgb(170, 60, 170)
};

def monster_hp(k: long) -> long {
    let c = k;
    if (c < 0) { c = 0; };
    if (c > M_KINDS - 1) { c = M_KINDS - 1; };
    M_HP[c]
};

def monster_dmg(k: long, depth: long) -> long {
    let c = k;
    if (c < 0) { c = 0; };
    if (c > M_KINDS - 1) { c = M_KINDS - 1; };
    let d = depth - 1;
    if (d < 0) { d = 0; };
    M_DMG[c] + d * M_DEPTH_DMG
};

// roll_kind(depth) -- what wanders in.  The distribution is a flat choice out of
// as many species as the depth has earned, so level 1 has rats and bats and
// level 5 has all five.
def roll_kind(depth: long) -> long {
    let pool = depth + 1;
    if (pool > M_KINDS) { pool = M_KINDS; };
    if (pool < 2) { pool = 2; };
    rnd.below(pool)
};

export { T_WALL, T_FLOOR, T_DOOR, T_STAIRS, TERRAIN_CODES, Terrain,
          terrain_at, terrain_tag, terrain_name, terrain_glyph,
          K_GOLD, K_POTION, K_SCROLL, K_DAGGER, KINDS, Loot,
          L_GOLD, L_POTION, L_SCROLL, L_DAGGER,
          make_gold, make_potion, make_scroll, make_dagger,
          loot_kind, loot_name, loot_action, loot_heal, loot_reveal, loot_dmg,
          loot_glyph, loot_name_of_kind,
          A_NOTHING, A_HEAL, A_REVEAL, A_WIELD,
          M_RAT, M_BAT, M_SNAKE, M_ORC, M_TROLL, M_KINDS, M_HP, M_DMG, M_GLYPH,
          M_NAME, monster_kind_name, monster_glyph, monster_colour,
          monster_hp, monster_dmg, roll_kind };
