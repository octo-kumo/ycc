// game.y -- the state and the turn.
//
// ===========================================================================
// THE TURN LOOP WITHOUT `break` OR `continue`
// ===========================================================================
//
// Y has neither (ORCHESTRATOR.md 2.9 -- `break` and `continue` are undefined
// names today).  A roguelike turn is four decisions that all want to "do this
// and stop", so the whole module is written around the two idioms that work:
//
//   EARLY EXIT -- an `else if` chain, or a guard flag the loop condition tests.
//   `turn` below is the chain; it has no flag anywhere:
//
//       def turn(dx, dy) -> long {          // 1 = a turn was spent
//           let spent = 0;
//           let nx = PX + dx;
//           let ny = PY + dy;
//           if (!dungeon.in_map(nx, ny)) {
//               say(MSG_WALL);              // bumped the edge: no turn spent
//           } else if (closed door) {
//               open it; say(MSG_DOOR); spent = 1;
//           } else {
//               let mi = monster_at(nx, ny);
//               if (mi >= 0) { player_hits(mi); spent = 1; }
//               else { spent = walk_to(nx, ny); };
//           };
//           spent
//       };
//
//   SKIP -- wrap the body in a positive condition rather than jumping over it.
//   `monsters_act` below is the shape: a dead monster is simply one the
//   condition is false for, and a monster the player cannot see is one whose
//   `else` arm is the empty block:
//
//       if (MALIVE[i] == 1 && STATUS == S_ALIVE) {
//           if (adjacent)      { attack_player(i); }
//           else if (in_sight) { step_towards(i); };
//       };
//
//   THE LOOP CONDITION IS ALSO A GUARD -- `free_floor` and `spawn_monsters` find
//   a free tile by rejection, so instead of `break` they run the rejection count
//   down: `let live = tries < 60; while (live) { ... }`.  A bounded rejection
//   loop cannot spin, and when it gives up it returns a defined answer (-1)
//   rather than trapping.
//
// `step` is the one place the two are composed: the player's action spends a
// turn or does not, and only a spent turn runs the monsters and recomputes the
// field of view.  That is why bumping a wall costs nothing, which is both the
// right roguelike rule and what makes a scripted walk into a wall harmless.
//
// ===========================================================================
// NO ALLOCATION ON THE TURN PATH
// ===========================================================================
//
// Everything below is a module-level fixed array or a `long`.  The per-turn
// calls are `dungeon.opaque`, `fov.los`, `fov.compute`, `fov.clear` and a few
// flat loops -- and `fov.clear` is the one to watch, a 8192-iteration loop that
// runs EVERY turn.  It is still free: it writes into an array allocated at
// module load, and the heap is an arena that never frees (ORCHESTRATOR.md 2.7),
// so "free" here means "allocates nothing", not "is fast".  `heap_used()` across
// 10000 turns is the measurement, and it is zero.
//
// THE MESSAGE LOG STORES IDS, NOT STRINGS, and the inventory stores a KIND CODE
// plus a union rebuilt on demand.  Both are deliberate: a `str` log allocates
// every time a message changes, and a union array of eight slots cannot even be
// written in a fixed-array literal (`let INV: [Loot; 8] = [0; 0; ...]` is a
// parse error), so `slot_loot` builds one union at a time -- on a keypress,
// which is a cold path.

import dungeon;
import fov;
import rnd;
import rules;

// ---------------------------------------------------------------------------
// constants
// ---------------------------------------------------------------------------

const MAX_MOBS = 48;
const INV_SLOTS = 8;
const MSG_SLOTS = 3;
const RADIUS = 8;                 // how far the eye reaches
const START_HP = 20;
const BASE_DMG = 2;               // bare hands
const LEVEL_MOBS = 1;             // monsters per room, and two spare
const LEVEL_ITEMS = 2;            // items per room, and two spare
const FLOOR_TRIES = 60;           // bound on the rejection sampler

// message ids.  These index MSGTEXT, so they must stay in step with it -- which
// is the one thing a table of literals and a list of consts cannot do by
// themselves, and is why the ids are consecutive from 0 and asserted below.
const MSG_NONE = 0;
const MSG_WALL = 1;
const MSG_DOOR = 2;
const MSG_HIT = 3;
const MSG_KILL = 4;
const MSG_HURT = 5;
const MSG_GRAB = 6;
const MSG_EMPTY = 7;
const MSG_FULL = 8;
const MSG_DRINK = 9;
const MSG_MAP = 10;
const MSG_WIELD = 11;
const MSG_DOWN = 12;
const MSG_WIN = 13;
const MSG_DIE = 14;
const MSG_GOLD = 15;
const MSG_BADSLOT = 16;
const MSG_BREATH = 17;
const MSG_COUNT = 18;

// walking out of the dungeon
const S_ALIVE = 0;
const S_DEAD = 1;
const S_ESCAPED = 2;
const S_FAILED = 3;               // the generator could not make a level

// ---------------------------------------------------------------------------
// the message table
// ---------------------------------------------------------------------------
//
// `str` literals in a module-level array, indexed by message id.  Indexing an
// array of `str` hands back the existing string; it does not build a new one, so
// reading the log is free.  Four of the eighteen need the subject's name and are
// assembled on demand in `message_text_full` -- on a cold path, once per
// message, which is not per frame.
let MSGTEXT: [str; 18] = [
    "",
    "The wall is solid.",
    "You push the door open.",
    "", "",
    "",
    "",
    "Nothing here to pick up.",
    "Your pack is full.",
    "The potion warms you.",
    "The scroll blazes, and the level is charted.",
    "",
    "You take the stair down.",
    "You climb out with the amulet of Y, and the dungeon lets you go.",
    "You die. The dungeon keeps what it kills.",
    "You pocket the gold.",
    "That slot is empty.",
    "The dungeon breathes."
];

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

let MAP_W: long = 40;
let MAP_H: long = 24;
let SEED_BASE: long = 1;
let MAX_DEPTH: long = 1;

let PX: long = 0;
let PY: long = 0;
let P_HP: long = START_HP;
let P_MAXHP: long = START_HP;
let P_GOLD: long = 0;
let P_WIELD: rules.Loot = rules.make_dagger(0);   // bare hands until you find one
let P_BONUS: long = 0;
let DEPTH: long = 1;
let TURNS: long = 0;
let KILLS: long = 0;
let SEEN_N: long = 0;
let STATUS: long = S_ALIVE;

// explored-but-not-visible: the distinction is two arrays, not one
let SEEN: [long; 8192] = [0; 8192];

// the roster: five parallel [long; 48] arrays rather than 48 records, because a
// record literal inside a loop body costs 40 bytes an iteration and this is
// inside a loop body
let MN: long = 0;
let MX: [long; 48] = [0; 48];
let MY: [long; 48] = [0; 48];
let MHP: [long; 48] = [0; 48];
let MMAX: [long; 48] = [0; 48];
let MKIND: [long; 48] = [0; 48];
let MALIVE: [long; 48] = [0; 48];

// ground items
let ITEM: [long; 8192] = [0; 8192];
let ICNT: [long; 8192] = [0; 8192];

// the pack: a kind code and a count per slot, with the union rebuilt on demand
let INV_KIND: [long; 8] = [0; 8];
let INVN: [long; 8] = [0; 8];
let INV_FULL: [long; 8] = [0; 8];

// the log: ids and their subject, never strings
let MSG: [long; 3] = [0; 3];
let SUBJ: [long; 3] = [0; 3];
let MSGFULL: [long; 3] = [0; 3];    // 1 = the text needs the subject's name

// what the last turn reported, for the per-turn digest
let LAST_DMG: long = 0;
let LAST_TAKEN: long = 0;
let LAST_KILLED: long = 0;
let INVULN: long = 0;               // --invuln: a measurement aid, see the help

// ---------------------------------------------------------------------------
// the message log
// ---------------------------------------------------------------------------

// message_text(id) -> str -- the plain table lookup, bounds-checked.
def message_text(id: long) -> str {
    let k = id;
    if (k < 0) { k = 0; };
    if (k > MSG_COUNT - 1) { k = MSG_COUNT - 1; };
    MSGTEXT[k]
};

// message_line(i) -> str -- the text of log entry i, with the subject spliced in
// when the message needs one.  Cold path: once per message that changes, never
// per frame more than three times.
def message_line(i: long) -> str {
    let id = MSG[i];
    let s = SUBJ[i];
    let base = message_text(id);
    if (MSGFULL[i] != 1) { return base; };
    if (id == MSG_HIT) {
        return "You hit the " + rules.monster_kind_name(s) + ".";
    };
    if (id == MSG_KILL) {
        return "The " + rules.monster_kind_name(s) + " dies.";
    };
    if (id == MSG_HURT) {
        return "The " + rules.monster_kind_name(s) + " hits you for "
             + tostring(rules.monster_dmg(s, DEPTH)) + ".";
    };
    if (id == MSG_GRAB) {
        return "Picked up the " + rules.loot_name_of_kind(s) + ".";
    };
    if (id == MSG_WIELD) {
        return "You ready the " + rules.loot_name_of_kind(s) + ".";
    };
    base
};

// ── the message text, rendered as BYTES ────────────────────────────────────
//
// `message_line` above builds a `str`, which is the right thing for a caller that
// wants a string.  The frame path does NOT want a string: a Y string built at run
// time lives on a heap that is never freed, so drawing the message log every
// frame leaked one string per changed line -- measured 33 bytes a frame on a
// screen that had settled to nothing but one monster's health bar.
//
// So the same sentence is composed here into a fixed [long; 160] of byte values
// and a length, and view.y draws it a codepoint at a time.  Zero allocation, and
// the wording still lives in exactly one place: `message_text` above for the
// plain lines, and the four subject-named ones here.
let MSG_OUT: [long; 160] = [32; 160];
let MSG_OUT_N: long = 0;

def put_ch(c: long) -> void {
    if (MSG_OUT_N < 160) {
        MSG_OUT[MSG_OUT_N] = c;
        MSG_OUT_N = MSG_OUT_N + 1;
    };
};

def put_t(t: str) -> void {
    let n = len(t);
    let j = 0;
    while (j < n) {
        put_ch(byte_at(t, j));
        j = j + 1;
    };
};

def put_num(v: long) -> void {
    let n = if (v < 0) { 0 } else { v };
    let d = 1;
    let t = n;
    while (t >= 10) {
        t = t / 10;
        d = d + 1;
    };
    let k = d;
    while (k > 0) {
        put_ch(48 + n % 10);
        n = n / 10;
        k = k - 1;
    };
};

// message_line_bytes(i) -> long -- compose log entry i into MSG_OUT and answer
// how many bytes it wrote.  The buffer is module-level, so this allocates nothing
// and is safe to call from a frame loop.
def message_line_bytes(i: long) -> long {
    MSG_OUT_N = 0;
    let id = MSG[i];
    let s = SUBJ[i];
    if (MSGFULL[i] == 0) {
        put_t(message_text(id));
    } else if (id == MSG_HIT) {
        put_t("You hit the ");
        put_t(rules.monster_kind_name(s));
        put_t(".");
    } else if (id == MSG_KILL) {
        put_t("The ");
        put_t(rules.monster_kind_name(s));
        put_t(" dies.");
    } else if (id == MSG_HURT) {
        put_t("The ");
        put_t(rules.monster_kind_name(s));
        put_t(" hits you for ");
        put_num(rules.monster_dmg(s, DEPTH));
        put_t(".");
    } else if (id == MSG_GRAB) {
        put_t("Picked up the ");
        put_t(rules.loot_name_of_kind(s));
        put_t(".");
    } else if (id == MSG_WIELD) {
        put_t("You ready the ");
        put_t(rules.loot_name_of_kind(s));
        put_t(".");
    } else {
        put_t(message_text(id));
    };
    MSG_OUT_N
};

// say(id, subject) -- push onto the log, oldest out.  No `break`: the shift is a
// plain loop over the three slots and the write lands at the end.  `subject` is
// only read by the four messages that name something.
def say(id: long, subject: long) -> void {
    let i = 0;
    while (i < MSG_SLOTS - 1) {
        MSG[i] = MSG[i + 1];
        SUBJ[i] = SUBJ[i + 1];
        MSGFULL[i] = MSGFULL[i + 1];
        i = i + 1;
    };
    MSG[MSG_SLOTS - 1] = id;
    SUBJ[MSG_SLOTS - 1] = subject;
    MSGFULL[MSG_SLOTS - 1] = 0;
    if (id == MSG_HIT || id == MSG_KILL || id == MSG_HURT || id == MSG_GRAB
        || id == MSG_WIELD) {
        MSGFULL[MSG_SLOTS - 1] = 1;
    };
};

// say_last(id) -- rewrite the newest line instead of adding one, for a message
// that supersedes the last (descending, dying, escaping).
def say_last(id: long) -> void {
    MSG[MSG_SLOTS - 1] = id;
    SUBJ[MSG_SLOTS - 1] = 0;
    MSGFULL[MSG_SLOTS - 1] = 0;
};

// ---------------------------------------------------------------------------
// level setup
// ---------------------------------------------------------------------------

def clear_items() -> void {
    let i = 0;
    while (i < 8192) {
        ITEM[i] = 0;
        ICNT[i] = 0;
        i = i + 1;
    };
};

// free_floor() -> long -- a random walkable tile that is not the start and not
// the stairs, found by rejection.  The rejection count runs DOWN instead of
// breaking out, and -1 is a defined answer, so a level too small to have a spare
// tile cannot spin or trap.
def free_floor() -> long {
    let tries = 0;
    let found = 0 - 1;
    let live = tries < FLOOR_TRIES;
    while (live) {
        tries = tries + 1;
        let x = rnd.below(MAP_W);
        let y = rnd.below(MAP_H);
        if (!dungeon.blocks(x, y) && !(x == PX && y == PY)
            && !(x == dungeon.STAIRS_X && y == dungeon.STAIRS_Y)) {
            found = y * dungeon.W + x;
            live = false;
        } else {
            live = tries < FLOOR_TRIES;
        };
    };
    found
};

def spawn_monsters() -> void {
    MN = 0;
    let want = dungeon.NROOMS * LEVEL_MOBS + 2;
    if (want > MAX_MOBS - 2) { want = MAX_MOBS - 2; };
    if (want < 0) { want = 0; };
    let placed = 0;
    let guard = 0;
    let cap = want * 4 + 8;
    // THE LOOP CONDITION IS THE GUARD.  An earlier version held a `live` flag
    // beside it and only refreshed the flag in the collision branch -- so after
    // the last wanted monster was placed the flag was still true and the loop
    // kept going until it happened to hit an occupied tile.  It put 36 monsters
    // on a level that asked for 28 and nobody noticed, because `mn` was reported
    // as MN.  Two conditions in the `while`, nothing to forget to update.
    while (placed < want && guard < cap) {
        guard = guard + 1;
        let k = free_floor();
        if (k >= 0 && MN < MAX_MOBS
            && monster_at(k % dungeon.W, k / dungeon.W) < 0) {
            MKIND[MN] = rules.roll_kind(DEPTH);
            MHP[MN] = rules.monster_hp(MKIND[MN]);
            MMAX[MN] = MHP[MN];
            MX[MN] = k % dungeon.W;
            MY[MN] = k / dungeon.W;
            MALIVE[MN] = 1;
            MN = MN + 1;
            placed = placed + 1;
        };
    };
}

def spawn_items() -> void {
    let want = dungeon.NROOMS * LEVEL_ITEMS + 2;
    let placed = 0;
    let guard = 0;
    let cap = want * 4 + 8;
    while (placed < want && guard < cap) {
        guard = guard + 1;
        let k = free_floor();
        if (k >= 0 && ITEM[k] == 0) {
            let roll = rnd.below(100);
            if (roll < 40) {
                ITEM[k] = rules.K_GOLD;
                ICNT[k] = 1 + rnd.below(9);
            } else if (roll < 70) {
                ITEM[k] = rules.K_POTION;
                ICNT[k] = 1;
            } else if (roll < 88) {
                ITEM[k] = rules.K_DAGGER;
                ICNT[k] = 1;
            } else {
                ITEM[k] = rules.K_SCROLL;
                ICNT[k] = 1;
            };
            placed = placed + 1;
        };
    };
}

// place_start_potion() -> long -- the room you start in always has one potion
// beside you, searched for EAST FIRST so a scripted walk can reach it in one
// move.  Not a cheat: a roguelike whose pack and whose `1` key are only
// discoverable when the dice say so teaches nothing in its first ten turns, and
// every classic does the same thing with a guaranteed tool near the entrance.
// The order is fixed, so it costs nothing and it is reproducible.
// The eight offsets are module level, not locals: an array LITERAL inside a def
// body is evaluated onto the heap every time the expression runs (72 bytes,
// measured -- SUGGESTIONS.md 7), and this file claims a per-turn heap delta of
// zero, which is a much easier claim to defend when there is no literal
// anywhere below the module-level bindings.
const ORD_X: [long; 8] = [1, 0, 0 - 1, 0, 1, 1, 0 - 1, 0 - 1];
const ORD_Y: [long; 8] = [0, 1, 0, 0 - 1, 0 - 1, 1, 1, 0 - 1];

def place_start_potion() -> void {
    let i = 0;
    let done = 0;
    while (i < 8 && done == 0) {
        let nx = PX + ORD_X[i];
        let ny = PY + ORD_Y[i];
        // whatever is already on the tile is REPLACED, not skipped: the point
        // is that the first press of `,` after one step east always works
        if (dungeon.in_map(nx, ny) && !dungeon.blocks(nx, ny)) {
            ITEM[ny * dungeon.W + nx] = rules.K_POTION;
            ICNT[ny * dungeon.W + nx] = 1;
            done = 1;
        } else {
            i = i + 1;
        };
    };
    if (done == 0) {
        // nowhere beside the start (a one-tile room, say): put it underfoot,
        // which is still reachable and still free
        ITEM[PY * dungeon.W + PX] = rules.K_POTION;
        ICNT[PY * dungeon.W + PX] = 1;
        done = 1;
    };
}

// enter_level(depth) -> long -- build the dungeon for this depth and stand the
// player in it.  The pack SURVIVES a descent; the HP survives; the level's
// monsters do not.  Returns 0 when the generator could not make two rooms,
// which the driver turns into a diagnostic rather than a game.
def enter_level(depth: long) -> long {
    DEPTH = depth;
    let rooms = dungeon.generate(SEED_BASE + depth * 1000003);
    if (rooms < 2) {
        STATUS = S_FAILED;
        return 0;
    };
    PX = dungeon.START_X;
    PY = dungeon.START_Y;
    clear_items();
    spawn_monsters();
    spawn_items();
    place_start_potion();
    fov.compute(PX, PY, RADIUS);
    explore();
    say_last(MSG_DOWN);
    1
};

// ---------------------------------------------------------------------------
// exploration
// ---------------------------------------------------------------------------

// explore() -> void -- fold VIS into SEEN.  THE explored/visible distinction:
// VIS is cleared and recomputed every turn, SEEN is never cleared, and the
// renderer draws an unseen tile solid black, a seen-but-dark tile in a dim
// colour and a lit tile bright.  Two arrays, not one, because "I remember this
// room" and "I can see this tile" are different facts.
def explore() -> void {
    let i = 0;
    let all = MAP_W * MAP_H;
    while (i < all) {
        if (fov.VIS[i] == 1 && SEEN[i] == 0) {
            SEEN[i] = 1;
            SEEN_N = SEEN_N + 1;
        };
        i = i + 1;
    };
};

def explored_pct() -> long {
    let all = MAP_W * MAP_H;
    if (all <= 0) { return 0; };
    SEEN_N * 100 / all
};

// ---------------------------------------------------------------------------
// monsters
// ---------------------------------------------------------------------------

def monster_at(x: long, y: long) -> long {
    let i = 0;
    let hit = 0 - 1;
    while (i < MN) {
        if (MALIVE[i] == 1 && MX[i] == x && MY[i] == y) {
            hit = i;
        };
        i = i + 1;
    };
    hit
};

def alive_count() -> long {
    let i = 0;
    let n = 0;
    while (i < MN) {
        if (MALIVE[i] == 1) { n = n + 1; };
        i = i + 1;
    };
    n
};

def attack_player(i: long) -> void {
    let dmg = rules.monster_dmg(MKIND[i], DEPTH);
    if (INVULN != 0) { dmg = 0; };
    P_HP = P_HP - dmg;
    LAST_TAKEN = LAST_TAKEN + dmg;
    say(MSG_HURT, MKIND[i]);
    if (P_HP <= 0) {
        P_HP = 0;
        STATUS = S_DEAD;
        say_last(MSG_DIE);
    };
};

def player_hits(i: long) -> void {
    let dmg = BASE_DMG + P_BONUS;
    MHP[i] = MHP[i] - dmg;
    LAST_DMG = LAST_DMG + dmg;
    if (MHP[i] <= 0) {
        MALIVE[i] = 0;
        KILLS = KILLS + 1;
        LAST_KILLED = LAST_KILLED + 1;
        // a corpse sometimes leaves gold, on the tile it died on
        if (rnd.chance(45)) {
            let k = MY[i] * dungeon.W + MX[i];
            if (ITEM[k] == 0) {
                ITEM[k] = rules.K_GOLD;
                ICNT[k] = 1 + rnd.below(5);
            };
        };
        say(MSG_KILL, MKIND[i]);
    } else {
        say(MSG_HIT, MKIND[i]);
    };
};

// step_towards(i) -> long -- one greedy step: x first, then y, and only into a
// tile that is neither a wall nor the player's own square.  A monster with
// nowhere to go simply does not move, which is what makes a corridor a safe
// place to rest.
def step_towards(i: long) -> void {
    let dx = PX - MX[i];
    let dy = PY - MY[i];
    let sx = if (dx > 0) { 1 } else if (dx < 0) { 0 - 1 } else { 0 };
    let sy = if (dy > 0) { 1 } else if (dy < 0) { 0 - 1 } else { 0 };
    let moved = 0;
    if (sx != 0 && !dungeon.blocks(MX[i] + sx, MY[i])
        && !(MX[i] + sx == PX && MY[i] == PY)) {
        MX[i] = MX[i] + sx;
        moved = 1;
    };
    if (moved == 0 && sy != 0 && !dungeon.blocks(MX[i], MY[i] + sy)
        && !(MX[i] == PX && MY[i] + sy == PY)) {
        MY[i] = MY[i] + sy;
        moved = 1;
    };
};

// monsters_act() -> void -- every visible monster takes one action.  A dead
// monster and a monster out of sight are both handled by the condition being
// false: that is the `continue` this language does not have, written as a
// positive test instead of a jump.
def monsters_act() -> void {
    let i = 0;
    while (i < MN) {
        if (MALIVE[i] == 1 && STATUS == S_ALIVE) {
            let adx = if (PX - MX[i] < 0) { MX[i] - PX } else { PX - MX[i] };
            let ady = if (PY - MY[i] < 0) { MY[i] - PY } else { PY - MY[i] };
            let seeing = fov.lit(MY[i] * dungeon.W + MX[i]);
            if (adx <= 1 && ady <= 1 && (adx != 0 || ady != 0)) {
                attack_player(i);
            } else if (seeing) {
                step_towards(i);
            };
        };
        i = i + 1;
    };
};

// ---------------------------------------------------------------------------
// the player's action
// ---------------------------------------------------------------------------

def attack_dmg() -> long {
    BASE_DMG + P_BONUS
};

def descend() -> long {
    if (DEPTH >= MAX_DEPTH) {
        STATUS = S_ESCAPED;
        say_last(MSG_WIN);
        return 1;
    };
    if (enter_level(DEPTH + 1) == 0) { return 0; };
    1
};

def walk_to(nx: long, ny: long) -> long {
    PX = nx;
    PY = ny;
    if (dungeon.tile_at(nx, ny) == rules.T_STAIRS) {
        return descend();
    };
    1
};

// slot_loot(n) -> rules.Loot -- the union for pack slot n.
//
// A fixed `[rules.Loot; 8]` cannot be written at all -- `= [0; 0; ...]` is a
// parse error and `= [0; 8]` is a long literal -- so the union is handed over
// here instead of living in an array.  It returns one of rules.y's FOUR
// PRE-BUILT module-level unions rather than calling make_potion() and friends:
// building a fresh one costs 40 bytes of heap (SUGGESTIONS.md 7), and this is
// still on a keypress path, and "a keypress allocates nothing" is a much better
// property than "a keypress allocates 120 bytes".  The four constants are built
// once at module load.
def slot_loot(n: long) -> rules.Loot {
    let k = rules.K_GOLD;
    if (n >= 0 && n < INV_SLOTS) { k = INV_KIND[n]; };
    let out: rules.Loot = rules.L_GOLD;
    if (k == rules.K_POTION) { out = rules.L_POTION; }
    else if (k == rules.K_SCROLL) { out = rules.L_SCROLL; }
    else if (k == rules.K_DAGGER) { out = rules.L_DAGGER; };
    out
};

def pack_add(kind: long, count: long) -> long {
    // prefer a slot already holding this kind, so potions stack
    let slot = 0 - 1;
    let i = 0;
    while (i < INV_SLOTS) {
        if (slot < 0 && INV_FULL[i] == 1 && INV_KIND[i] == kind) { slot = i; };
        i = i + 1;
    };
    if (slot < 0) {
        i = 0;
        while (i < INV_SLOTS) {
            if (slot < 0 && INV_FULL[i] == 0) { slot = i; };
            i = i + 1;
        };
    };
    if (slot < 0) { return 0 - 1; };
    if (INV_FULL[slot] == 0) {
        INV_FULL[slot] = 1;
        INV_KIND[slot] = kind;
        INVN[slot] = count;
    } else {
        INVN[slot] = INVN[slot] + count;
    };
    slot
};

// grab() -> long -- pick up whatever is underfoot.  Gold goes straight to the
// purse; the rest goes to a pack slot.
def grab() -> long {
    let k = PY * dungeon.W + PX;
    let kind = ITEM[k];
    if (kind == 0) {
        say(MSG_EMPTY, 0);
        return 0;
    };
    if (kind == rules.K_GOLD) {
        P_GOLD = P_GOLD + ICNT[k];
        ITEM[k] = 0;
        ICNT[k] = 0;
        say(MSG_GOLD, 0);
        return 1;
    };
    let slot = pack_add(kind, ICNT[k]);
    if (slot < 0) {
        say(MSG_FULL, 0);
        return 0;
    };
    ITEM[k] = 0;
    ICNT[k] = 0;
    say(MSG_GRAB, kind);
    1
};

def reveal_level() -> void {
    let i = 0;
    let all = MAP_W * MAP_H;
    while (i < all) {
        if (SEEN[i] == 0 && dungeon.tile_at(i % MAP_W, i / MAP_H) != rules.T_WALL) {
            SEEN[i] = 1;
            SEEN_N = SEEN_N + 1;
        };
        i = i + 1;
    };
};

// use_slot(n) -> long -- press 1..8.  A `match` on the union value itself, so
// what the key does is read off the thing and not off a code kept in step with
// it by hand.
def use_slot(n: long) -> long {
    if (n < 0 || n >= INV_SLOTS || INV_FULL[n] == 0) {
        say(MSG_BADSLOT, 0);
        return 0;
    };
    let what = slot_loot(n);
    let act = rules.loot_action(what);
    let spent = 0;
    if (act == rules.A_HEAL) {
        P_HP = P_HP + rules.loot_heal(what);
        if (P_HP > P_MAXHP) { P_HP = P_MAXHP; };
        INVN[n] = INVN[n] - 1;
        if (INVN[n] <= 0) { INV_FULL[n] = 0; };
        say(MSG_DRINK, 0);
        spent = 1;
    } else if (act == rules.A_REVEAL) {
        reveal_level();
        INVN[n] = INVN[n] - 1;
        if (INVN[n] <= 0) { INV_FULL[n] = 0; };
        say(MSG_MAP, 0);
        spent = 1;
    } else if (act == rules.A_WIELD) {
        P_WIELD = what;
        P_BONUS = rules.loot_dmg(what);
        say(MSG_WIELD, INV_KIND[n]);
        spent = 1;
    } else {
        say(MSG_EMPTY, 0);
    };
    spent
};

// turn(dx, dy) -> long -- one attempted player action.  1 means a turn was spent,
// which is what `step` tests.  The `else if` chain IS the early exit; there is
// no flag anywhere in here.
//
// The chain is also the ONLY thing keeping the player inside the walls.  It
// checks the off-map case, then the closed-door case, then the blocking case,
// and only the last `else` may actually move somebody.  An earlier version had
// no blocking case at all -- a closed door was handled and a wall was not, so
// `w` walked you straight into the masonry and the position invariant the
// validator checks caught it on turn 5.  Bumping a wall costs no turn, which is
// the right roguelike rule and what makes a scripted walk into a wall harmless.
def turn(dx: long, dy: long) -> long {
    if (STATUS != S_ALIVE) { return 0; };
    let nx = PX + dx;
    let ny = PY + dy;
    let spent = 0;
    if (!dungeon.in_map(nx, ny)) {
        say(MSG_WALL, 0);
    } else if (dungeon.tile_at(nx, ny) == rules.T_DOOR
               && !dungeon.is_open_door(nx, ny)) {
        dungeon.open_door(nx, ny);
        say(MSG_DOOR, 0);
        spent = 1;
    } else if (dungeon.blocks(nx, ny)) {
        say(MSG_WALL, 0);
    } else {
        let mi = monster_at(nx, ny);
        if (mi >= 0) {
            player_hits(mi);
            spent = 1;
        } else {
            spent = walk_to(nx, ny);
        };
    };
    spent
};

// spend() -> void -- the world takes its turn: the monsters move, the clock
// advances, the field of view is recomputed and the explored map folded.  Split
// out of `step` because picking something up and using a pack slot also spend a
// turn, and they must do it through the SAME code, not a second copy.
def spend() -> void {
    if (STATUS == S_ALIVE) {
        monsters_act();
        TURNS = TURNS + 1;
        fov.compute(PX, PY, RADIUS);
        explore();
    };
};

// step(dx, dy) -> long -- a full turn: the player's action, then the world.  All
// of it writes into module-level arrays, and `heap_used()` across 10000 calls is
// the measurement that says so.
def step(dx: long, dy: long) -> long {
    LAST_DMG = 0;
    LAST_TAKEN = 0;
    LAST_KILLED = 0;
    let spent = turn(dx, dy);
    if (spent == 1) {
        spend();
    };
    spent
};

// setup(w, h, seed_base, depth) -> long -- everything before the first turn.
def setup(w: long, h: long, seed_base: long, depth: long) -> long {
    MAP_W = w;
    MAP_H = h;
    SEED_BASE = seed_base;
    MAX_DEPTH = depth;
    STATUS = S_ALIVE;
    dungeon.configure(w, h);
    let i = 0;
    while (i < 8192) {
        SEEN[i] = 0;
        i = i + 1;
    };
    SEEN_N = 0;
    TURNS = 0;
    KILLS = 0;
    P_HP = START_HP;
    P_MAXHP = START_HP;
    P_GOLD = 0;
    let k = 0;
    while (k < INV_SLOTS) {
        INV_FULL[k] = 0;
        INV_KIND[k] = 0;
        INVN[k] = 0;
        k = k + 1;
    };
    enter_level(1)
};

export { MAX_MOBS, INV_SLOTS, MSG_SLOTS, RADIUS, START_HP, BASE_DMG,
          FLOOR_TRIES, MSG_COUNT, LEVEL_MOBS, LEVEL_ITEMS,
          MAP_W, MAP_H, SEED_BASE, MAX_DEPTH,
          PX, PY, P_HP, P_MAXHP, P_GOLD, P_WIELD, P_BONUS, DEPTH, TURNS,
          KILLS, SEEN_N, STATUS, SEEN, MN, MX, MY, MHP, MMAX, MKIND, MALIVE,
          ITEM, ICNT, INV_KIND, INVN, INV_FULL, MSG, SUBJ, MSGFULL,
          LAST_DMG, LAST_TAKEN, LAST_KILLED, INVULN,
          S_ALIVE, S_DEAD, S_ESCAPED, S_FAILED,
          MSG_NONE, MSG_WALL, MSG_DOOR, MSG_HIT, MSG_KILL, MSG_HURT, MSG_GRAB,
          MSG_EMPTY, MSG_FULL, MSG_DRINK, MSG_MAP, MSG_WIELD, MSG_DOWN,
          MSG_WIN, MSG_DIE, MSG_GOLD, MSG_BADSLOT, MSG_BREATH,
          MSGTEXT, MSG_OUT, message_text, message_line, message_line_bytes,
          say, say_last,
          clear_items, free_floor, spawn_monsters, spawn_items,
          place_start_potion, enter_level,
          explore, explored_pct, monster_at, alive_count,
          attack_player, player_hits, step_towards, monsters_act, attack_dmg,
          descend, walk_to, slot_loot, pack_add, grab, reveal_level, use_slot,
          turn, spend, step, setup };
