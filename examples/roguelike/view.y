// view.y -- drawing.  One function for the terminal (through tui) and one for
// the deterministic text dump, both reading the same per-tile decision, so the
// two can never disagree about what the player can see.
//
// ===========================================================================
// THE PER-TILE DECISION, ONCE
// ===========================================================================
//
// `tile_at(x, y) -> Glyph` is the single place that answers "what is on this
// tile, and how brightly".  It is a RECORD, and a record return is by reference
// so it costs nothing -- but a record LITERAL in a loop body costs 40 bytes an
// iteration (SUGGESTIONS.md 7), so `tile_at` fills one module-level record and
// hands back the same one every call.  A caller reads it and throws it away
// before the next call.  That is the idiom for "I want a struct on a per-cell
// path" in a language with no destructuring return.
//
// The five states, and why there are five and not two:
//
//   unseen        solid black          a tile never seen
//   remembered    dim, and ':' for a wall    seen at some point, not now lit
//   lit           bright               in the current field of view
//   on top        full colour          a monster, an item, the player, the stairs
//   lit wall      mid grey             you can see the FACE of a wall
//
// which is the explored/visible distinction rendered: two arrays in game.y, and
// five cases here.
//
// ===========================================================================
// NO ALLOCATION ON THE FRAME PATH
// ===========================================================================
//
// `draw_window` and `draw_status` write only into the caller's tui.Surface and
// into module-level scratch.  The status line formats its numbers a digit at a
// time through a module-level [long; 12] rather than calling tostring() -- a
// string built once a frame is 40 bytes a frame, which over an hour at 30 fps is
// 4.3 MB.  The one string the frame path does build is `game.message_line()`,
// which assembles the newest message's text; that happens at most three times a
// frame, is bounded by the message length, and is the price of naming the monster
// you just hit.

import dungeon;
import fov;
import game;
import rules;
import textout;
import tui;

type Glyph = { cp: long, fg: long, bg: long, lit: long, seen: long };

let G: Glyph = { cp: 32, fg: 0, bg: 0, lit: 0, seen: 0 };

// ---- the palette.  `let`, not `const`: tui.rgb is a call.
let C_VOID = tui.rgb(3, 3, 5);
let C_WALL_FAR = tui.rgb(30, 30, 36);
let C_WALL_FAR_BG = tui.rgb(8, 8, 11);
let C_WALL_NEAR = tui.rgb(74, 72, 68);
let C_WALL_NEAR_BG = tui.rgb(15, 15, 19);
let C_FLOOR_FAR = tui.rgb(58, 56, 50);
let C_FLOOR_NEAR = tui.rgb(132, 130, 120);
let C_DOOR = tui.rgb(170, 126, 60);
let C_STAIRS = tui.rgb(255, 226, 120);
let C_YOU = tui.rgb(255, 255, 224);
let C_GOLD = tui.rgb(224, 198, 88);
let C_POTION = tui.rgb(120, 210, 140);
let C_SCROLL = tui.rgb(200, 190, 130);
let C_DAGGER = tui.rgb(170, 190, 210);
let C_HUD = tui.rgb(150, 158, 170);
let C_HUD_DIM = tui.rgb(86, 92, 102);
let C_HP = tui.rgb(220, 90, 90);
let C_HP_OK = tui.rgb(140, 210, 140);
let C_GOLD_HUD = tui.rgb(224, 198, 88);
let C_MSG = tui.rgb(196, 186, 166);

// ---- the ASCII glyph set for the --no-tty dump.  The characters are chosen so
// a remembered floor is distinguishable from a visible one WITHOUT colour:
// ',' is what you remember, '.' is what you can see, ':' is a remembered wall and
// '#' a lit one.  That is what makes the text dump evidence about the field of
// view rather than a decoration of it.
const T_VOID = 32;        // ' '
const T_WALL_FAR = 58;    // ':'
const T_WALL_NEAR = 35;   // '#'
const T_FLOOR_FAR = 44;   // ','
const T_FLOOR_NEAR = 46;  // '.'
const T_DOOR = 43;        // '+'
const T_STAIRS = 62;      // '>'
const T_YOU = 64;         // '@'
const T_BAR = 124;        // '|'
const T_GOLD = 36;        // '$'

// item_ascii(kind) -- the ground glyph for a loot kind, as an ASCII codepoint.
def item_ascii(kind: long) -> long {
    if (kind == rules.K_GOLD) { return T_GOLD; };
    if (kind == rules.K_POTION) { return 33; };      // '!'
    if (kind == rules.K_SCROLL) { return 63; };      // '?'
    47                                          // '/'
};

// ---------------------------------------------------------------------------
// the per-tile decision
// ---------------------------------------------------------------------------

// tile_at(x, y) -> Glyph -- fills and returns the ONE module-level record.  A
// caller must read it before the next call; nothing here keeps it.
def tile_at(x: long, y: long) -> Glyph {
    let k = y * dungeon.W + x;
    let t = dungeon.TILE[k];
    let seen = game.SEEN[k];
    let lit = fov.VIS[k];
    let cp = T_VOID;
    let fg = C_VOID;
    let bg = C_VOID;
    let is_item = game.ITEM[k] != 0;
    let mi = -1;
    let mine = false;
    if (x == game.PX && y == game.PY) {
        mine = true;
    } else {
        mi = game.monster_at(x, y);
    };
    if (mine) {
        cp = T_YOU;
        fg = C_YOU;
        bg = tui.rgb(26, 26, 32);
    } else if (mi >= 0) {
        cp = rules.monster_glyph(game.MKIND[mi]);
        fg = rules.monster_colour(game.MKIND[mi]);
        bg = if (lit == 1) { tui.rgb(26, 22, 26) } else { tui.rgb(9, 9, 12) };
    } else if (lit == 1 && t == rules.T_STAIRS) {
        cp = T_STAIRS;
        fg = C_STAIRS;
        bg = tui.rgb(24, 22, 16);
    } else if (lit == 1 && is_item) {
        cp = item_ascii(game.ITEM[k]);
        fg = if (game.ITEM[k] == rules.K_GOLD) { C_GOLD }
             else if (game.ITEM[k] == rules.K_POTION) { C_POTION }
             else if (game.ITEM[k] == rules.K_SCROLL) { C_SCROLL }
             else { C_DAGGER };
        bg = tui.rgb(22, 22, 26);
    } else if (lit == 1 && t == rules.T_DOOR) {
        cp = T_DOOR;
        fg = C_DOOR;
        bg = tui.rgb(20, 18, 14);
    } else if (lit == 1 && t == rules.T_WALL) {
        // a lit wall: you can see its FACE, and it is drawn brighter than one
        // you only remember -- which is the whole point of having both arrays
        cp = T_WALL_NEAR;
        fg = C_WALL_NEAR;
        bg = C_WALL_NEAR_BG;
    } else if (seen == 1) {
        if (t == rules.T_WALL) {
            cp = T_WALL_FAR;
            fg = C_WALL_FAR;
            bg = C_WALL_FAR_BG;
        } else if (t == rules.T_STAIRS) {
            cp = T_STAIRS;
            fg = tui.rgb(110, 100, 60);
            bg = tui.rgb(10, 10, 13);
        } else if (t == rules.T_DOOR) {
            cp = T_DOOR;
            fg = tui.rgb(90, 70, 40);
            bg = tui.rgb(10, 10, 13);
        } else if (is_item) {
            cp = item_ascii(game.ITEM[k]);
            fg = tui.rgb(80, 74, 56);
            bg = tui.rgb(10, 10, 13);
        } else {
            cp = T_FLOOR_FAR;
            fg = C_FLOOR_FAR;
            bg = tui.rgb(10, 10, 13);
        };
    } else if (t == rules.T_WALL) {
        cp = T_VOID;
        fg = C_VOID;
        bg = C_VOID;
    } else {
        cp = T_VOID;
        fg = C_VOID;
        bg = C_VOID;
    };
    G.cp = cp;
    G.fg = fg;
    G.bg = bg;
    G.lit = lit;
    G.seen = seen;
    G
};

// ---------------------------------------------------------------------------
// the terminal view
// ---------------------------------------------------------------------------

// cam_x(camw) / cam_y(camh) -- the camera's top-left corner, clamped so the
// window never runs off the map.  Two defs because each is used once and a
// record return would allocate.
def cam_x(camw: long) -> long {
    let span = game.MAP_W - camw;
    if (span < 0) { span = 0; };
    let at = game.PX - camw / 2;
    if (at < 0) { at = 0; };
    if (at > span) { at = span; };
    at
};

def cam_y(camh: long) -> long {
    let span = game.MAP_H - camh;
    if (span < 0) { span = 0; };
    let at = game.PY - camh / 2;
    if (at < 0) { at = 0; };
    if (at > span) { at = span; };
    at
};

// draw_window -- the camera.  The band is first filled edge to edge with the
// void colour, so a terminal wider than the dungeon reads as "the map ends
// here" rather than as stale pixels the framebuffer was never told about: tui
// leaves unwritten cells at SKIP, and a SKIP cell emits nothing at all, so the
// terminal would keep whatever was on it from three frames ago.
def draw_window(s: tui.Surface, top: long, camw: long, camh: long) -> void {
    let r = 0;
    while (r < camh) {
        tui.hline(s, top + r, 0, s.cols, 32, C_VOID, C_VOID);
        r = r + 1;
    };
    let x0 = cam_x(camw);
    let y0 = cam_y(camh);
    r = 0;
    while (r < camh) {
        let c = 0;
        while (c < camw) {
            let mx = x0 + c;
            let my = y0 + r;
            if (mx >= 0 && my >= 0 && mx < game.MAP_W && my < game.MAP_H) {
                tile_at(mx, my);
                tui.put(s, top + r, c, G.cp, G.fg, G.bg);
            };
            c = c + 1;
        };
        r = r + 1;
    };
};

// ---- the status line, formatted a digit at a time -----------------------
//
// DIG is module level because an array literal in a def body allocates every time
// the expression runs (SUGGESTIONS.md 7): a literal here would leak 72 bytes a
// frame, 1.5 MB an hour at 30 fps.
let DIG: [long; 12] = [48; 12];

def sline(s: tui.Surface, row: long, col: long, v: long, fg: long, bg: long) -> long {
    let q = if (v < 0) { 0 } else { v };
    let n = 0;
    while (q > 0 && n < 12) {
        DIG[11 - n] = 48 + q % 10;
        q = q / 10;
        n = n + 1;
    };
    let at = col;
    let i = 12 - n;
    while (i < 12) {
        tui.put(s, row, at, DIG[i], fg, bg);
        at = at + 1;
        i = i + 1;
    };
    at
};

def bar(s: tui.Surface, row: long, col: long, frac: long, len: long,
        fg: long, bg: long) -> long {
    // A run of cells, filled to `frac` percent.  No `break`: the loop runs the
    // whole bar and the condition decides what each cell is.
    let k = 0;
    let at = col;
    while (k < len) {
        let on = k * 100 / len < frac;
        tui.put(s, row, at, if (on) { 9608 } else { 9617 }, fg,
               if (on) { fg } else { bg });
        at = at + 1;
        k = k + 1;
    };
    at
};

def draw_status(s: tui.Surface, row: long) -> void {
    let bg = tui.rgb(12, 12, 16);
    let c = 0;
    while (c < s.cols) {
        tui.put(s, row, c, 32, C_HUD, bg);
        c = c + 1;
    };
    let c2 = 2;
    tui.text(s, row, c2, "Y", C_HUD, bg);
    c2 = c2 + 2;
    c2 = sline(s, row, c2, game.DEPTH, C_STAIRS, bg);
    tui.text(s, row, c2, "/", C_HUD_DIM, bg); c2 = c2 + 1;
    c2 = sline(s, row, c2, game.MAX_DEPTH, C_HUD_DIM, bg);
    tui.text(s, row, c2, " T", C_HUD, bg); c2 = c2 + 2;
    c2 = sline(s, row, c2, game.TURNS, C_HUD, bg);
    tui.text(s, row, c2, " HP", C_HUD, bg); c2 = c2 + 3;
    let hpfg = if (game.P_HP * 4 <= game.P_MAXHP) { C_HP }
               else if (game.P_HP * 4 <= game.P_MAXHP * 2) { C_STAIRS }
               else { C_HP_OK };
    c2 = bar(s, row, c2, game.P_HP * 100 / game.P_MAXHP, 8, hpfg, tui.rgb(40, 20, 20));
    c2 = c2 + 1;
    c2 = sline(s, row, c2, game.P_HP, hpfg, bg);
    tui.text(s, row, c2, "/", C_HUD_DIM, bg); c2 = c2 + 1;
    c2 = sline(s, row, c2, game.P_MAXHP, C_HUD_DIM, bg);
    tui.text(s, row, c2, " hit", C_HUD, bg); c2 = c2 + 4;
    c2 = sline(s, row, c2, game.attack_dmg(), C_DAGGER, bg);
    tui.text(s, row, c2, " gold", C_HUD, bg); c2 = c2 + 5;
    c2 = sline(s, row, c2, game.P_GOLD, C_GOLD_HUD, bg);
    tui.text(s, row, c2, " foes", C_HUD, bg); c2 = c2 + 5;
    c2 = sline(s, row, c2, game.alive_count(), C_HP, bg);
    tui.text(s, row, c2, " seen", C_HUD, bg); c2 = c2 + 5;
    c2 = sline(s, row, c2, game.explored_pct(), C_HUD, bg);
    tui.text(s, row, c2, "%", C_HUD_DIM, bg); c2 = c2 + 1;
    if (game.STATUS == game.S_DEAD) {
        tui.text(s, row, c2, " YOU ARE DEAD", C_HP, bg);
        c2 = c2 + 12;
    } else if (game.STATUS == game.S_ESCAPED) {
        tui.text(s, row, c2, " YOU ESCAPED", C_HP_OK, bg);
        c2 = c2 + 12;
    };
    if (s.cols >= 56) {
        tui.text(s, row, s.cols - 30, "hjkl yubn move  , grab  1-8 use  ? help",
                C_HUD_DIM, bg);
    };
};

// draw_pack -- the pack along the bottom, one glyph and a count per slot.  The
// numbers go through `sline`, so the whole panel is codepoints and integers and
// never a formatted string.
def draw_pack(s: tui.Surface, row: long) -> void {
    let bg = tui.rgb(10, 10, 13);
    let c = 1;
    let z = 0;
    while (z < s.cols) {
        tui.put(s, row, z, 32, C_HUD_DIM, bg);
        z = z + 1;
    };
    tui.put(s, row, 0, 9553, C_HUD_DIM, bg);
    let k = 0;
    while (k < game.INV_SLOTS) {
        if (game.INV_FULL[k] == 1) {
            tui.text(s, row, c, " [", C_HUD_DIM, bg);
            c = c + 2;
            c = sline(s, row, c, k + 1, C_HUD, bg);
            tui.put(s, row, c, 93, C_HUD_DIM, bg);
            c = c + 1;
            tui.put(s, row, c, item_ascii(game.INV_KIND[k]), C_GOLD, bg);
            c = c + 1;
            if (game.INVN[k] > 1) {
                c = sline(s, row, c, game.INVN[k], C_HUD, bg);
                tui.text(s, row, c, "]", C_HUD_DIM, bg);
                c = c + 1;
            } else {
                tui.put(s, row, c, 93, C_HUD_DIM, bg);
                c = c + 1;
            };
        };
        k = k + 1;
    };
};

// MSGID/MSGSUB/MSGFULL -- what the message log looked like when it was last
// DRAWN, and `invalidate()` forgets it.
//
// `game.message_line(i)` builds a string -- it has to, to splice the name of the
// monster you just hit into the sentence -- and a Y string built at run time
// lives on a heap that is never freed.  Drawing all three lines every frame
// measured 3064 bytes over six frames of play, which is a leak with a frame
// count in it and exactly the sort of thing this example is claiming not to do.
// So the log is drawn only when its CONTENTS change, which is once per message
// and not once per frame.  `tui.flush_diff` would have thrown the bytes away
// anyway: the cells are identical.
let MSGID: [long; 3] = [0 - 1; 3];
let MSGSUB: [long; 3] = [0 - 1; 3];
let MSGFLAG: [long; 3] = [0 - 1; 3];

// invalidate -- forget what the log looked like.  Called once at start-up and
// after a resize, which is the only other time the cells underneath it change.
def invalidate() -> void {
    let i = 0;
    while (i < 3) {
        MSGID[i] = 0 - 1;
        MSGSUB[i] = 0 - 1;
        MSGFLAG[i] = 0 - 1;
        i = i + 1;
    };
};

// draw_msgs -- the three most recent messages, newest at the bottom.
def draw_msgs(s: tui.Surface, row: long) -> void {
    let bg = tui.rgb(9, 9, 12);
    let r = 0;
    while (r < 3) {
        tui.hline(s, row + r, 0, s.cols, 32, C_HUD, bg);
        r = r + 1;
    };
    let i = 0;
    while (i < game.MSG_SLOTS) {
        let fresh = game.MSG[i] != MSGID[i] || game.SUBJ[i] != MSGSUB[i]
                    || game.MSGFULL[i] != MSGFLAG[i];
        if (fresh) {
            let msgrow = row + i;
            if (game.MSG[i] != game.MSG_NONE) {
                let age = game.MSG_SLOTS - 1 - i;
                let fg = if (age == 0) { C_MSG } else { C_HUD_DIM };
                // drawn from game.MSG_OUT, not from a string: see the note on
                // message_line_bytes in game.y
                let n = game.message_line_bytes(i);
                let j = 0;
                while (j < n) {
                    tui.put(s, msgrow, 2 + j, game.MSG_OUT[j], fg, bg);
                    j = j + 1;
                };
            };
            MSGID[i] = game.MSG[i];
            MSGSUB[i] = game.SUBJ[i];
            MSGFLAG[i] = game.MSGFULL[i];
        };
        i = i + 1;
    };
};

// ---------------------------------------------------------------------------
// the text dump
// ---------------------------------------------------------------------------

// ROW is the scratch row for the text dump: one growable [long], appended to per
// cell and handed to textout.map_line.  A fixed [long; 128] cannot be passed
// (a fixed array is not a [long]), and this is once per map row, not per cell, so
// the amortised growth is irrelevant.
let ROW: [long] = [];

// ascii_at(x, y) -> long -- the text-dump glyph.  The same decision tree as
// `tile_at`, expressed in ASCII, and the only reason the dump exists is that
// this mapping is readable in a diff.
//
// THE `mine` BRANCH IS A BRANCH, NOT A PRE-ASSIGNMENT.  An earlier version set
// `cp = T_YOU` and then let the `seen` arm overwrite it, so the player was drawn
// as a remembered floor tile -- which is exactly the sort of thing a golden file
// hides, because the map still looked like a map.
def ascii_at(x: long, y: long) -> long {
    let k = y * dungeon.W + x;
    let t = dungeon.TILE[k];
    let seen = game.SEEN[k];
    let lit = fov.VIS[k];
    let cp = T_VOID;
    let mi = 0 - 1;
    let mine = false;
    if (x == game.PX && y == game.PY) {
        mine = true;
    } else {
        mi = game.monster_at(x, y);
    };
    if (mine) {
        cp = T_YOU;
    } else if (mi >= 0 && lit == 1) {
        cp = rules.monster_glyph(game.MKIND[mi]);
    } else if (lit == 1 && t == rules.T_STAIRS) {
        cp = T_STAIRS;
    } else if (lit == 1 && game.ITEM[k] != 0) {
        cp = item_ascii(game.ITEM[k]);
    } else if (lit == 1 && t == rules.T_DOOR) {
        cp = T_DOOR;
    } else if (lit == 1 && t == rules.T_WALL) {
        cp = T_WALL_NEAR;
    } else if (seen == 1) {
        if (t == rules.T_WALL) { cp = T_WALL_FAR; }
        else if (t == rules.T_STAIRS) { cp = T_STAIRS; }
        else if (t == rules.T_DOOR) { cp = T_DOOR; }
        else if (game.ITEM[k] != 0) { cp = item_ascii(game.ITEM[k]); }
        else { cp = T_FLOOR_FAR; };
    } else {
        cp = T_VOID;
    };
    cp
};

def dump_map(title: str) -> void {
    textout.out_str(title);
    textout.out_str("\n");
    let y = 0;
    while (y < game.MAP_H) {
        ROW = [];
        let x = 0;
        while (x < game.MAP_W) {
            ROW += ascii_at(x, y);
            x = x + 1;
        };
        textout.map_line(ROW);
        y = y + 1;
    };
};

// ---------------------------------------------------------------------------
// the glyph legend
// ---------------------------------------------------------------------------
//
// LEGEND is built ONCE, at start-up, by appending one character at a time from a
// glyph string -- and the append is `line += chr(byte)`, NOT `line = line +
// glyph[i]`, because `str + byte` dereferences the byte's numeric value as a
// pointer and dies with SIGSEGV:
//
//     $ refs/ycc.ref min.y -o min && ./min      # print("x" + "abc"[0]);
//     Segmentation fault
//
// filed as examples/BUGS.md, "`str + byte` segfaults".  `chr()` returns a real
// `str` and is therefore safe -- at a cost worth knowing: `chr` builds its
// one-character string ON THE HEAP, about 80 bytes a call, so it is right here
// (four calls, once, at start-up) and wrong on any per-frame path.  Everything on
// the frame path writes codepoints into the surface directly instead.
let LEGEND: str = "";

def build_legend() -> void {
    // The bound is len(ASCII), never a hand-counted number: a string index is
    // bounds-checked at RUN TIME and traps to stdout, and miscounting a literal's
    // length is exactly the kind of typo that only shows up on someone else's
    // input.  (This file counted ten characters as eleven, once.)
    const ASCII = "#.+>@rsboT";
    LEGEND = "";
    let i = 0;
    let n = len(ASCII);
    while (i < n) {
        LEGEND += chr(ASCII[i]);
        i = i + 1;
    };
};

def legend() -> str {
    if (LEGEND == "") { build_legend(); };
    LEGEND
};

export { Glyph, C_VOID, C_WALL_FAR, C_WALL_NEAR, C_FLOOR_FAR, C_FLOOR_NEAR,
          C_DOOR, C_STAIRS, C_YOU, C_GOLD, C_HUD, C_HP, C_MSG, T_VOID,
          T_WALL_FAR, T_WALL_NEAR, T_FLOOR_FAR, T_FLOOR_NEAR, T_DOOR, T_STAIRS,
          T_YOU, T_BAR,
          item_ascii, tile_at, cam_x, cam_y, draw_window, draw_status,
          draw_pack, draw_msgs, invalidate, sline, bar, ascii_at, dump_map,
          build_legend,
          legend };
