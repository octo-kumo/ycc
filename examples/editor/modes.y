// modes.y -- the mode machine: NORMAL, INSERT, VISUAL and the COMMAND line,
// the operator-pending state, the count, and the key-script decoder.
//
// One entry point, fn_feed(k) -> action, and everything -- the interactive
// loop, the scripted `--no-tty` run, and check.y -- goes through it.  That is
// deliberate: a property check that drove its own private copy of the logic
// would be testing nothing.
//
// ===========================================================================
// NO CHARACTER-LITERAL SYNTAX TO READ
//
// `'a'` is a LEXER ERROR in Y; the character literal is `c'a'` (see
// examples/BUGS.md, "'a' is not a character literal").  Every key test here is
// `ord("a")`, which needs no annotation and reads the same in the source.
// There is no `s[i]` byte in any of it either: indexing a str yields a byte
// and `str + byte` SEGFAULTS (filed), so a key table is ord() calls and never
// a string of characters indexed by the incoming key.
//
// ===========================================================================
// NO break, NO continue
//
// Both are undefined names today (ORCHESTRATOR.md 2.9), so every early exit is
// a `return` out of a small helper and every "skip this key" is a positive
// `if` around the body.  The dispatch is a chain of helpers rather than one
// long else-chain, because a helper can return and an else-branch cannot.
//
// ===========================================================================
// NO CLOSURES, AND NO LITERALS IN A LOOP
//
// A nested `def` would be the natural way to share the dispatch table, but a
// closure allocates and the C twin's value model has nowhere to put a
// function value.  So the dispatch is module-level state plus module-level
// functions.  The NAMED table below is a module-level literal on purpose: a
// record literal inside a loop body allocates 40 bytes an iteration
// (examples/SUGGESTIONS.md item 7, measured), and the discipline is the point
// even where the loop runs once.

import buf;
import tui;

// ---- modes ---------------------------------------------------------------
const NORMAL = 0;
const INSERT = 1;
const VISUAL = 2;
const COMMAND = 3;

def mode_name(m: long) -> str {
    if (m == NORMAL) { "NORMAL" } else if (m == INSERT) { "INSERT" } else if (m == VISUAL) { "VISUAL" } else { "COMMAND" }
};

// ---- what fn_feed() tells its caller -------------------------------------
const ACT_CONTINUE = 0;
const ACT_QUIT = 1;         // leave the editor loop, exit 0
const ACT_FAIL = 2;         // leave the editor loop, exit 1

// ---- state ---------------------------------------------------------------
let MODE = NORMAL;
let COUNT = 0;              // digits typed so far; 0 means none
let PCOUNT = 1;             // the count in force when an operator started
let COUNT_SET = false;      // a digit has been typed
let PCOUNT_SET = false;     // ... and one was in force when the operator started
let PEND_OP = 0;            // buf.OP_Y / OP_D / OP_C, 0 for none
let PEND_G = false;         // a `g` has been typed and wants its second half
let PEND_I = 0;             // `i` or `a` after an operator: waiting for the letter
let PEND_A = false;         // ...and whether it was `a`
let VANCH = 0;              // VISUAL's anchor line
let SEARCH_BACK = false;

// ---- the command line ----------------------------------------------------
// A module-level fixed buffer, so a keystroke in COMMAND mode and a redraw
// while in it both allocate nothing.  fn_cmd_text() exists for the few places
// that want a str (running a command, the scripted dump); the redraw path
// reads fn_cmd_byte()/fn_cmd_len() instead.
const CMD_MAX = 512;
let CMD: [byte; 512] = [0; 512];
let CMD_LEN = 0;

// ===========================================================================
// the key script
// ===========================================================================
//
// `--keys` takes one string and decodes it into the SAME longs tui.read_key()
// returns, so a scripted run and a real one execute identical code.  Names are
// spelled in angle brackets and everything else is a literal byte:
//
//   <Esc> <CR> <NL> <BS> <Tab> <Del> <Up> <Down> <Left> <Right>
//   <Home> <End> <PgUp> <PgDn> <F1> <F2> <Space> <C-r> ...
//
// An unknown <name> is a usage error rather than a silently ignored byte, so a
// typo in a script fails loudly instead of doing nothing.
const SCRIPT_MAX = 4096;
let SCRIPT: [long; 4096] = [0; 4096];
let SCRIPT_N = 0;
let SCRIPT_I = 0;
let SCRIPT_ERR = "";

type Named = { name: str, code: long };

let NAMED: [Named] = [
    { name: "Esc",  code: tui.KEY_ESC },
    { name: "CR",   code: 13 },
    { name: "NL",   code: 10 },
    { name: "BS",   code: 127 },
    { name: "Tab",  code: 9 },
    { name: "Del",  code: tui.KEY_DELETE },
    { name: "Up",   code: tui.KEY_UP },
    { name: "Down", code: tui.KEY_DOWN },
    { name: "Left", code: tui.KEY_LEFT },
    { name: "Right", code: tui.KEY_RIGHT },
    { name: "Home", code: tui.KEY_HOME },
    { name: "End",  code: tui.KEY_END },
    { name: "PgUp", code: tui.KEY_PGUP },
    { name: "PgDn", code: tui.KEY_PGDN },
    { name: "F1",   code: tui.KEY_F1 },
    { name: "F2",   code: tui.KEY_F2 },
    { name: "Space", code: 32 }
];

// The offset of the first byte `b` at or after `from0`, or -1.  str.index_of has
// no `from` argument, which is why this exists.
def find_byte_from(s: str, b: long, from0: long) -> long {
    let hit = 0 - 1;
    let i = from0;
    let go = i < len(s);
    while (go) {
        if (byte_at(s, i) == b) { hit = i; go = false; } else { i = i + 1; go = i < len(s) }
    };
    hit
};

// Decode the text between `<` and `>`, or -2 for "not a name at all".  The
// table above is the one place a name is spelled; <C-x> is the exception, being
// derivable: a terminal in raw mode with IEXTEN cleared sends ^A..^Z as bytes
// 1..26.
def named_code(name: str) -> long {
    let hit = 0 - 2;
    let i = 0;
    while (i < len(NAMED)) {
        if (NAMED[i].name == name) { hit = NAMED[i].code; i = len(NAMED); } else { i = i + 1 };
    };
    if (hit == 0 - 2 && len(name) == 3 && name[0:2] == "C-") {
        let b = ord(name[2:]);
        if (b >= 97 && b <= 122) { b = b - 32 };
        if (b >= 65 && b <= 90) { hit = b - 64 }
    };
    hit
};

// Decode the whole script.  Returns 0, or the 1-based offset of the first byte
// it could not read with SCRIPT_ERR filled in.
def script_decode(s: str) -> long {
    SCRIPT_N = 0;
    SCRIPT_I = 0;
    SCRIPT_ERR = "";
    let bad = 0;
    let i = 0;
    while (i < len(s)) {
        let b = ord(s[i:]);
        if (b == ord("<")) {
            // The closing `>` has to be looked for FROM HERE.  s.index_of(">")
            // searches the whole string from 0, so with two <name> tokens in one
            // script the first one's scan ran on and swallowed everything up to
            // the second `>`: "unknown key name <>" for a script that was fine.
            let close = find_byte_from(s, 62, i + 1);
            if (close < 0) {
                SCRIPT_ERR = "unterminated <name> at offset " + tostring(i);
                bad = i + 1;
                i = len(s)
            } else {
                let name = s[i + 1:close];
                let code = named_code(name);
                if (code == 0 - 2) {
                    SCRIPT_ERR = "unknown key name <" + name + "> at offset " + tostring(i);
                    bad = i + 1;
                    i = len(s)
                } else {
                    if (SCRIPT_N < SCRIPT_MAX) { SCRIPT[SCRIPT_N] = code; SCRIPT_N = SCRIPT_N + 1 };
                    i = close + 1
                }
            }
        } else {
            if (SCRIPT_N < SCRIPT_MAX) { SCRIPT[SCRIPT_N] = b; SCRIPT_N = SCRIPT_N + 1 };
            i = i + 1
        }
    };
    bad
};

def script_count() -> long { SCRIPT_N };
def script_at(i: long) -> long { if (i >= 0 && i < SCRIPT_N) { SCRIPT[i] } else { tui.KEY_NONE } };
def script_take() -> long {
    let k = tui.KEY_NONE;
    if (SCRIPT_I < SCRIPT_N) { k = SCRIPT[SCRIPT_I]; SCRIPT_I = SCRIPT_I + 1 };
    k
};
def script_more() -> bool { SCRIPT_I < SCRIPT_N };
def script_rewind() { SCRIPT_I = 0 };
def script_used() -> long { SCRIPT_I };

// ===========================================================================
// the command line
// ===========================================================================

def cmd_reset() -> void { CMD_LEN = 0 };
def cmd_len() -> long { CMD_LEN };
// `CMD[i]` is a byte and `0` is a long, and disagreeing if arms make the if
// VOID (the void redesign), so the byte is widened explicitly.
def cmd_byte(i: long) -> long { if (i >= 0 && i < CMD_MAX) { let v: long = CMD[i]; v } else { 0 } };

def cmd_push(b: long) -> void {
    if (CMD_LEN < CMD_MAX) {
        CMD[CMD_LEN] = b & 255;
        CMD_LEN = CMD_LEN + 1
    }
};

def cmd_back() -> void {
    if (CMD_LEN > 0) { CMD_LEN = CMD_LEN - 1 }
};

def cmd_text() -> str {
    let out = "";
    let i = 0;
    while (i < CMD_LEN) { out += chr(CMD[i]); i = i + 1 };
    out
};

// ===========================================================================
// mode transitions
// ===========================================================================

def mode() -> long { MODE };
def pending_op() -> long { PEND_OP };
def pending_g() -> bool { PEND_G };
def visual_anchor() -> long { VANCH };

def set_mode(m: long) -> void {
    // Only on the way OUT of INSERT.  Keying this on the NEW mode being INSERT
    // looks equivalent and is not: entering INSERT after `cw` closed the undo
    // block and stepped the cursor LEFT, so `caw` typed its replacement one
    // character before the start of the word ("cawX" on "the lazy dog" gave
    // "the lazXy").  A property check that only compared texts could not see it;
    // check.y's (b) now asserts the cursor's column as well.
    if (MODE == INSERT && m != INSERT) {
        // Closing the undo block the keystrokes shared is what makes one `u`
        // take back the whole run of typing rather than one character -- vi's
        // undo block.  The cursor also steps one character left, because in
        // INSERT it sits *after* the character it was just typed over.
        buf.end_change();
        let ln = buf.cursor_line();
        let s = buf.line_at(ln);
        let c = buf.cursor_col();
        if (c > 0 && c < len(s)) {
            buf.goto(ln, buf.prev_start(s, c), false)
        } else {
            buf.clamp_cursor(false);
            buf.scroll_fix()
        }
    };
    MODE = m;
    COUNT = 0;
    COUNT_SET = false;
    PCOUNT = 1;
    PCOUNT_SET = false;
    PEND_OP = 0;
    PEND_G = false;
    PEND_I = 0;
    PEND_A = false
};

def enter_insert() -> void { set_mode(INSERT) };

// ===========================================================================
// counts
// ===========================================================================

def count_now() -> long { if (COUNT < 1) { 1 } else { COUNT } };

def is_digit(k: long) -> bool { k >= 48 && k <= 57 };

// tui.read_key() NEVER answers 27: a bare ESC is decoded into tui.KEY_ESC,
// which is 4096.  Comparing against 27 alone works in a script whose <Esc> the
// decoder turned into 4096 and silently does nothing on a real terminal -- and
// "silently does nothing" here means INSERT mode never ends, so everything typed
// after an Escape is inserted into the file instead.  Both spellings are accepted
// because 27 is what a non-raw read would hand back.
def is_esc(k: long) -> bool { k == 27 || k == tui.KEY_ESC };

def take_count() -> long {
    let c = COUNT;
    COUNT = 0;
    COUNT_SET = false;
    if (c < 1) { 1 } else { c }
};

// The count as TYPED, with 0 for "none": what G and gg need, because `G` and
// `1G` are different commands.  Every other motion wants at least one, which is
// take_count().
def raw_count() -> long {
    let c = COUNT;
    COUNT = 0;
    COUNT_SET = false;
    if (c < 1) { 0 } else { c }
};

// The count an operator+motion pair uses: the one in force when the operator
// started times the one in force now.  That is what makes `2d3w` mean six
// words and `2dd` mean two lines, and it is why PCOUNT is kept separately from
// COUNT rather than the two being one field.
def op_count() -> long {
    let n = op_count_raw();
    if (n < 1) { 1 } else { n }
};

// Same product, but 0 when no count was typed anywhere -- so `dG` reaches the
// last line and `d3G` reaches the third, which is what makes both spellings do
// what they look like.
def op_count_raw() -> long {
    let a = PCOUNT;
    if (a < 1) { a = 1 };
    let b = COUNT;
    if (b < 1) { b = 1 };
    let n = a * b;
    let had = COUNT_SET || PCOUNT_SET;
    COUNT = 0;
    COUNT_SET = false;
    PCOUNT_SET = false;
    if (had) { n } else { 0 }
};

def op_id(k: long) -> long {
    if (k == ord("d")) { buf.OP_D } else if (k == ord("c")) { buf.OP_C } else { buf.OP_Y }
};

def op_char(op: long) -> str {
    if (op == buf.OP_D) { "d" } else if (op == buf.OP_C) { "c" } else { "y" }
};

// ===========================================================================
// INSERT
// ===========================================================================

def insert_key(k: long) -> void {
    if (is_esc(k)) { set_mode(NORMAL); return };
    if (k == 13 || k == 10) { buf.split_at(buf.cursor_line(), buf.cursor_col()); return };
    if (k == 127 || k == 8) { buf.backspace_insert(); return };
    if (k >= 32 && k < 127) {
        buf.insert_byte(buf.cursor_line(), buf.cursor_col(), k);
        buf.goto(buf.cursor_line(), buf.cursor_col() + 1, true);
        return
    };
    if (k == 9) {
        buf.insert_byte(buf.cursor_line(), buf.cursor_col(), 9);
        buf.goto(buf.cursor_line(), buf.cursor_col() + 1, true);
        return
    };
    // The arrow keys move the cursor without inserting, which is what every
    // editor does and costs three lines here.
    let ln = buf.cursor_line();
    let s = buf.line_at(ln);
    if (k == tui.KEY_LEFT) { buf.goto(ln, buf.prev_start(s, buf.cursor_col()), true); return };
    if (k == tui.KEY_RIGHT) { buf.goto(ln, buf.adv(s, buf.cursor_col()), true); return };
    if (k == tui.KEY_HOME) { buf.goto(ln, 0, true); return };
    if (k == tui.KEY_END) { buf.goto(ln, len(s), true); return };
    if (k == tui.KEY_UP) { buf.goto_motion(buf.M_K, 1); buf.clamp_cursor(true); buf.scroll_fix(); return };
    if (k == tui.KEY_DOWN) { buf.goto_motion(buf.M_J, 1); buf.clamp_cursor(true); buf.scroll_fix(); return };
    if (k == tui.KEY_DELETE) {
        if (buf.delete_chars(1) != 0) { buf.clamp_cursor(true); buf.scroll_fix() };
        return
    };
    if (k == tui.KEY_ESC) { set_mode(NORMAL); return }
};

// ===========================================================================
// VISUAL  (linewise only -- `V`.  README says so; there is no `v`.)
// ===========================================================================

def enter_visual() -> void {
    VANCH = buf.cursor_line();
    set_mode(VISUAL)
};

// The anchor to the cursor, both inclusive.
def visual_span() -> buf.Span {
    let a = VANCH;
    let b = buf.cursor_line();
    let lo = a;
    let hi = b;
    if (b < a) { lo = b; hi = a };
    buf.make_span(lo, 0, hi, 0, true)
};

def visual_line_count() -> long { visual_span().hi_line - visual_span().lo_line + 1 };

def visual_key(k: long) -> void {
    if (is_esc(k)) { set_mode(NORMAL); return };
    if (k == ord("o")) {
        // `o` puts the cursor at the other end, which is what makes a
        // multi-line visual selection adjustable in the direction you did not
        // first drag.
        let c = buf.cursor_line();
        buf.goto(VANCH, buf.first_nonspace(buf.line_at(VANCH)), false);
        VANCH = c;
        return
    };
    if (k == ord("d") || k == ord("x")) { visual_op(buf.OP_D); return };
    if (k == ord("c")) { visual_op(buf.OP_C); return };
    if (k == ord("y")) { visual_op(buf.OP_Y); return };
    if (is_digit(k)) { COUNT = COUNT * 10 + (k - 48); COUNT_SET = true; return };
    if (k == ord("G")) { buf.goto_motion(buf.M_G, raw_count()); return };
    let m = buf.motion_id(k, COUNT > 0);
    if (m != buf.M_NONE) { buf.goto_motion(m, take_count()); return };
    if (k == tui.KEY_LEFT) { buf.goto_motion(buf.M_H, 1); return };
    if (k == tui.KEY_RIGHT) { buf.goto_motion(buf.M_L, 1); return };
    if (k == tui.KEY_UP) { buf.goto_motion(buf.M_K, 1); return };
    if (k == tui.KEY_DOWN) { buf.goto_motion(buf.M_J, 1); return };
    if (k == tui.KEY_HOME) { buf.goto_motion(buf.M_ZERO, 1); return };
    if (k == tui.KEY_END) { buf.goto_motion(buf.M_DOLLAR, 1); return };
    if (k == tui.KEY_PGUP) { buf.scroll_page(0 - 1); return };
    if (k == tui.KEY_PGDN) { buf.scroll_page(1); return };
    if (k == ord("n")) { search_next(SEARCH_BACK); return };
    if (k == ord("N")) { search_next(!SEARCH_BACK); return };
    if (k == ord(":")) { set_mode(NORMAL); enter_command(); return };
    buf.msg("(visual) unknown key")
};

def visual_op(op: long) -> void {
    let sp = visual_span();
    if (buf.apply_span(sp, op) == 1) {
        buf.msg("nothing in the visual selection");
        set_mode(NORMAL);
        return
    };
    if (op == buf.OP_C) { enter_insert(); return };
    set_mode(NORMAL)
};

// ===========================================================================
// the COMMAND line
// ===========================================================================

def enter_command() -> void {
    cmd_reset();
    set_mode(COMMAND)
};

def command_key(k: long) -> long {
    if (is_esc(k)) { set_mode(NORMAL); return ACT_CONTINUE };
    if (k == 13 || k == 10) {
        let text = cmd_text();
        set_mode(NORMAL);
        return ex(text)
    };
    if (k == 127 || k == 8) { cmd_back(); return ACT_CONTINUE };
    if (k == 9) { cmd_push(32); return ACT_CONTINUE };
    if (k >= 32 && k < 127) { cmd_push(k); return ACT_CONTINUE };
    ACT_CONTINUE
};

// Run one ex command.  Returns ACT_CONTINUE, ACT_QUIT or ACT_FAIL, and every
// diagnostic goes through buf.msg so it reaches the status line AND the
// scripted dump: a refusal that only reached the terminal would be invisible to
// `diff EXPECTED`, which is the whole point of --no-tty.
def ex(line0: str) -> long {
    let s = line0;
    if (len(s) == 0) { return ACT_CONTINUE };
    let ch = ord(s[0:]);
    let rest = s[1:];

    if (s == "q") {
        if (!buf.dirty()) { return ACT_QUIT };
        buf.msg("E37: no write since last change (add ! to override)");
        return ACT_CONTINUE
    };
    if (s == "q!") { return ACT_QUIT };
    // :w, :w FILE, :w!, :wq, :wq FILE, :x, :x FILE
    if (s == "wq" || s == "x") {
        if (!write("")) { return ACT_FAIL };
        return ACT_QUIT
    };
    if (s[0:3] == "wq " || s[0:2] == "x ") {
        let tail = s[2:];
        if (!write(tail)) { return ACT_FAIL };
        return ACT_QUIT
    };
    if (s == "w" || s == "w!") {
        if (!write("")) { return ACT_FAIL };
        return ACT_CONTINUE
    };
    if (s[0:2] == "w ") {
        let tail = s[1:];
        if (!write(tail)) { return ACT_FAIL };
        return ACT_CONTINUE
    };
    if (s == "u") { return undo_cmd() };
    if (s == "redo" || s == "redo!") { return redo_cmd() };
    if (s == "noh" || s == "nohlsearch") { return ACT_CONTINUE };
    if (ch == ord("s")) { return ex_sub(rest, false) };
    if (ch == ord("%") && len(rest) > 1 && rest[0:1] == "s") { return ex_sub(rest[1:], true) };
    if (ch == ord("/") || ch == ord("?")) { return ex_search(s[1:], ch == ord("?")) };
    if (all_digits(s)) { return ex_line(tolong(s)) };
    buf.msg("E492: Not an editor command: " + s);
    ACT_CONTINUE
};

def all_digits(s: str) -> bool {
    let ok = len(s) > 0;
    let i = 0;
    while (i < len(s) && ok) {
        let b = ord(s[i:]);
        if (b < 48 || b > 57) { ok = false };
        i = i + 1
    };
    ok
};

// :w [path]
def write(path0: str) -> bool {
    let p = path0;
    if (len(p) > 0 && p[0:1] == " ") { p = p[1:] };
    if (len(p) > 1 && p[0:1] == "!") { p = p[1:] };
    if (buf.save(p)) {
        buf.msg("\"" + buf.path() + "\" " + tostring(buf.nlines()) + "L, " + tostring(buf.nbytes()) + "B written");
        return true
    };
    if (len(p) == 0) { buf.msg("E32: No file name"); } else { buf.msg("E212: Can't open file for writing: " + p) };
    false
};

def undo_cmd() -> long {
    if (buf.undo()) {
        buf.msg("1 change; before");
        return ACT_CONTINUE
    };
    buf.msg("E1: Already at oldest change");
    ACT_CONTINUE
};

def redo_cmd() -> long {
    if (buf.redo()) {
        buf.msg("1 change; after");
        return ACT_CONTINUE
    };
    buf.msg("E35: Already at newest change");
    ACT_CONTINUE
};

// :[range]s/pat/rep/[g] -- the cursor's line, or every line with a leading %.
// The count the command reports is the number of replacements ACTUALLY made,
// which check.y's (b) holds against an independent count.
def ex_sub(rest: str, whole_file: bool) -> long {
    let body = rest;
    if (len(body) > 0 && body[0:1] == " ") { body = body[1:] };
    if (len(body) < 2 || body[0:1] != "/") {
        buf.msg("E486: Pattern not found: " + rest);
        return ACT_CONTINUE
    };
    let close = second_sep(body);
    if (close < 0) {
        buf.msg("E486: Pattern not found: " + rest);
        return ACT_CONTINUE
    };
    let pat = unescape(body[1:close]);
    let tail = body[close + 1:];
    let stop = third_sep(tail);
    let rep = "";
    let flags = "";
    if (stop < 0) {
        // No closing delimiter.  A trailing run of flag letters is then the
        // flags -- that is what makes `:s/a/b/g` work, which is how everyone
        // writes it.  The cost is that a replacement ENDING in g, c, i or I with
        // no closing delimiter is read as flags (`:s/a/big` means rep "bi",
        // flags "g"); write the closing delimiter and there is no ambiguity,
        // which is what the property check does.
        let all = tail;
        rep = all;
        let cut = len(all);
        let go = cut > 0;
        while (go && is_flag_letter(byte_at(all, cut - 1))) { cut = cut - 1; go = cut > 0 };
        if (cut < len(all)) { flags = all[cut:]; rep = all[0:cut] }
    } else {
        rep = tail[0:stop];
        flags = tail[stop + 1:];
        rep = unescape(rep)
    };
    let glob = flags.contains("g");
    let l0 = 0;
    let l1 = 0;
    if (whole_file) { l0 = 0; l1 = buf.nlines() - 1; } else { l0 = buf.cursor_line(); l1 = buf.cursor_line() };
    // `bad` is a BOOL and not a negative sentinel reused as a flag: the first
    // version of this loop used `failed = -1` for "still running" and then asked
    // `failed < 0` at the end as well, so every :s///g reported E35.
    let total = 0;
    let bad = false;
    let ln = l0;
    while (ln <= l1 && !bad) {
        let c = buf.substitute_line(ln, pat, rep, glob);
        if (c < 0) { bad = true; } else { total = total + c };
        ln = ln + 1
    };
    if (bad) {
        buf.msg("E35: no previous regular expression");
        return ACT_CONTINUE
    };
    if (total == 0) {
        buf.msg("E486: Pattern not found: " + pat);
        return ACT_CONTINUE
    };
    buf.clamp_cursor(false);
    buf.scroll_fix();
    let many = total == 1 ? "" : "s";
    let lines = l1 - l0 + 1;
    let lmany = lines == 1 ? "" : "s";
    buf.msg(tostring(total) + " substitution" + many + " on " + tostring(lines) + " line" + lmany);
    ACT_CONTINUE
};

// Where a delimiter closes a field.  `from` is where to start scanning, so the
// same scanner serves the pattern and the replacement.  A backslash escapes the
// next byte, which is what makes `\/` usable inside a pattern or a replacement
// -- the one piece of vi's substitute syntax worth having, since without it a
// path or a URL cannot be substituted at all.
def delim_at(s: str, from0: long) -> long {
    let n = len(s);
    let i = from0;
    let hit = 0 - 1;
    let go = i < n;
    while (go) {
        let b = byte_at(s, i);
        if (b == 92) { i = i + 2; go = i < n }
        else if (b == 47) { hit = i; go = false }
        else { i = i + 1; go = i < n }
    };
    hit
};

// The offset of the delimiter that closes the PATTERN.
def second_sep(s: str) -> long { delim_at(s, 1) };

// The offset of the delimiter that closes the REPLACEMENT.
def third_sep(s: str) -> long { delim_at(s, 0) };

// `\/` back to `/`.  Only that one escape is recognised; anything else is left
// exactly as written, so a Windows path or a `\t` in a substitution survives.
def unescape(s: str) -> str {
    let out = "";
    let i = 0;
    while (i < len(s)) {
        let b = byte_at(s, i);
        if (b == 92 && i + 1 < len(s) && byte_at(s, i + 1) == 47) {
            out += "/";
            i = i + 2
        } else {
            out += s[i:i + 1];
            i = i + 1
        }
    };
    out
}

// The letters vi reads as flags: g (every match), c (confirm), i / I (case).
def is_flag_letter(b: long) -> bool {
    b == 103 || b == 99 || b == 105 || b == 73
}

// /pattern and ?pattern
def ex_search(pat: str, back: bool) -> long {
    if (len(pat) == 0) {
        buf.msg("E35: no previous regular expression");
        return ACT_CONTINUE
    };
    buf.set_search(pat, back);
    SEARCH_BACK = back;
    let at = buf.next_match(buf.cursor_line(), pat, back);
    if (at < 0) {
        buf.msg("E486: Pattern not found: " + pat);
        return ACT_CONTINUE
    };
    buf.goto(at, buf.first_nonspace(buf.line_at(at)), false);
    buf.scroll_fix();
    ACT_CONTINUE
};

def search_next(back: bool) -> void {
    let pat = buf.search_pat();
    if (len(pat) == 0) {
        buf.msg("E35: no previous regular expression");
        return
    };
    let step = 1;
    if (back) { step = 0 - 1 };
    let at = buf.next_match(buf.cursor_line() + step, pat, back);
    if (at < 0) {
        buf.msg("E486: Pattern not found: " + pat);
        return
    };
    buf.goto(at, buf.first_nonspace(buf.line_at(at)), false);
    buf.scroll_fix()
};

// :N
def ex_line(n: long) -> long {
    let last = buf.nlines() - 1;
    let at = n - 1;
    if (at < 0) { at = 0 };
    if (at > last) { at = last };
    buf.goto(at, buf.first_nonspace(buf.line_at(at)), false);
    buf.scroll_fix();
    ACT_CONTINUE
};

// ===========================================================================
// NORMAL: motions, counts and the simple keys
// ===========================================================================

def normal_key(k: long) -> long {
    // `0` is the first-column motion only when no count is in hand; otherwise
    // it is a digit, which is why motion_id is asked about the count first.
    let m = buf.motion_id(k, COUNT > 0);
    if (m != buf.M_NONE) {
        buf.goto_motion(m, take_count());
        return ACT_CONTINUE
    };
    if (is_digit(k)) {
        COUNT = COUNT * 10 + (k - 48);
        COUNT_SET = true;
        return ACT_CONTINUE
    };
    // `g` is a prefix, not a command: it waits here for its second half, which
    // feed() hands to g_key().  `G` is a command and is handled separately,
    // because `G` and `1G` mean different things.
    if (k == ord("g")) { PEND_G = true; return ACT_CONTINUE };
    if (k == ord("G")) {
        buf.goto_motion(buf.M_G, raw_count());
        return ACT_CONTINUE
    };
    if (k == ord("d") || k == ord("c") || k == ord("y")) {
        PEND_OP = op_id(k);
        PCOUNT = count_now();
        PCOUNT_SET = COUNT_SET;
        COUNT = 0;
        COUNT_SET = false;
        return ACT_CONTINUE
    };
    if (k == ord("i")) { enter_insert(); return ACT_CONTINUE };
    if (k == ord("a")) {
        let ln = buf.cursor_line();
        buf.goto(ln, buf.adv(buf.line_at(ln), buf.cursor_col()), true);
        enter_insert();
        return ACT_CONTINUE
    };
    if (k == ord("A")) {
        buf.goto(buf.cursor_line(), len(buf.line_at(buf.cursor_line())), true);
        enter_insert();
        return ACT_CONTINUE
    };
    if (k == ord("V")) { enter_visual(); return ACT_CONTINUE };
    if (k == ord("o") || k == ord("O")) {
        buf.open_line(k == ord("o"));
        buf.clamp_cursor(true);
        buf.scroll_fix();
        enter_insert();
        return ACT_CONTINUE
    };
    if (k == ord("D")) { return op_motion(buf.OP_D, buf.M_DOLLAR) };
    if (k == ord("C")) { return op_motion(buf.OP_C, buf.M_DOLLAR) };
    if (k == ord("x")) { buf.delete_chars(take_count()); return ACT_CONTINUE };
    if (k == ord("X")) { COUNT = 0; buf.backspace_char(); return ACT_CONTINUE };
    if (k == ord("~")) { buf.tilde_case(take_count()); return ACT_CONTINUE };
    if (k == ord("J")) { join_here(); return ACT_CONTINUE };
    if (k == ord("p")) { buf.put(false, take_count()); return ACT_CONTINUE };
    if (k == ord("P")) { buf.put(true, take_count()); return ACT_CONTINUE };
    if (k == ord("u")) { return undo_cmd() };
    if (k == 18) { return redo_cmd() };
    if (k == ord(":")) { enter_command(); return ACT_CONTINUE };
    if (k == ord("/") || k == ord("?")) {
        enter_command();
        cmd_push(k);
        return ACT_CONTINUE
    };
    if (k == ord("n")) { search_next(SEARCH_BACK); return ACT_CONTINUE };
    if (k == ord("N")) { search_next(!SEARCH_BACK); return ACT_CONTINUE };
    if (k == ord("Z")) { return write_and_quit() };
    if (k == tui.KEY_LEFT) { buf.goto_motion(buf.M_H, 1); return ACT_CONTINUE };
    if (k == tui.KEY_RIGHT) { buf.goto_motion(buf.M_L, 1); return ACT_CONTINUE };
    if (k == tui.KEY_UP) { buf.goto_motion(buf.M_K, 1); return ACT_CONTINUE };
    if (k == tui.KEY_DOWN) { buf.goto_motion(buf.M_J, 1); return ACT_CONTINUE };
    if (k == tui.KEY_HOME) { buf.goto_motion(buf.M_ZERO, 1); return ACT_CONTINUE };
    if (k == tui.KEY_END) { buf.goto_motion(buf.M_DOLLAR, 1); return ACT_CONTINUE };
    if (k == tui.KEY_DELETE) { buf.delete_chars(1); return ACT_CONTINUE };
    if (k == tui.KEY_PGUP) { buf.scroll_page(0 - 1); return ACT_CONTINUE };
    if (k == tui.KEY_PGDN) { buf.scroll_page(1); return ACT_CONTINUE };
    // ^E and ^Y arrive as control bytes 5 and 4: half a screen each.
    if (k == 5) { buf.scroll_page(1); return ACT_CONTINUE };
    if (k == 4) { buf.scroll_page(0 - 1); return ACT_CONTINUE };
    if (is_esc(k)) { set_mode(NORMAL); return ACT_CONTINUE };
    if (k < 32) {
        buf.msg("unknown control key " + tostring(k));
        return ACT_CONTINUE
    };
    buf.msg("unknown key: " + chr(k));
    ACT_CONTINUE
};

def join_here() -> void {
    if (buf.join_down(buf.cursor_line())) {
        buf.clamp_cursor(false);
        buf.scroll_fix();
        return
    };
    buf.msg("only one line to join")
};

def write_and_quit() -> long {
    if (!write("")) { return ACT_FAIL };
    ACT_QUIT
};

// ===========================================================================
// operator-pending
// ===========================================================================

// `d`/`c`/`y` followed by a motion.
def op_motion(op: long, m: long) -> long {
    let sp = buf.op_range(m, op_count());
    PEND_OP = 0;
    if (buf.apply_span(sp, op) == 1) {
        buf.msg("nothing to " + op_char(op));
        PCOUNT = 1;
        return ACT_CONTINUE
    };
    after_op(op)
};

// As op_motion, but for G and gg, where "no count" has to stay distinguishable
// from "count 1".
def op_motion_raw(op: long, m: long) -> long {
    let sp = buf.op_range(m, op_count_raw());
    PEND_OP = 0;
    if (buf.apply_span(sp, op) == 1) {
        buf.msg("nothing to " + op_char(op));
        PCOUNT = 1;
        PCOUNT_SET = false;
        return ACT_CONTINUE
    };
    after_op(op)
}

// What happens after a successful operator.  A change goes to INSERT; a delete
// or a yank stays in NORMAL, with the cursor already placed by apply_span.
def after_op(op: long) -> long {
    PEND_OP = 0;
    PCOUNT = 1;
    COUNT = 0;
    COUNT_SET = false;
    PCOUNT_SET = false;
    if (op == buf.OP_C) { enter_insert(); return ACT_CONTINUE };
    set_mode(NORMAL);
    ACT_CONTINUE
};

// `d`/`c`/`y` followed by `i` or `a` and then the object's letter.
def op_textobj(op: long, around: bool, what: long) -> long {
    PEND_I = 0;
    PEND_OP = 0;
    PCOUNT = 1;
    COUNT = 0;
    COUNT_SET = false;
    PCOUNT_SET = false;
    let kind = 0;
    if (what == ord("w") || what == ord("W")) {
        if (around) { kind = buf.T_AW } else { kind = buf.T_IW }
    };
    if (what == ord("q") || what == 34) {
        if (around) { kind = buf.T_AQ } else { kind = buf.T_IQ }
    };
    if (kind == 0) {
        buf.msg("E488: Trailing characters");
        return ACT_CONTINUE
    };
    let sp = buf.textobj_range(kind);
    if (sp.lo_line < 0) {
        buf.msg("E486: Pattern not found");
        return ACT_CONTINUE
    };
    if (buf.apply_span(sp, op) == 1) {
        buf.msg("nothing to " + op_char(op));
        return ACT_CONTINUE
    };
    after_op(op)
};

// `dj` / `cj` / `yj`: vi's "join these lines".  With a count, n-1 joins.
def op_join(op: long) -> long {
    let n = op_count();
    PEND_OP = 0;
    PCOUNT = 1;
    COUNT = 0;
    COUNT_SET = false;
    PCOUNT_SET = false;
    if (n < 2) { n = 2 };
    let at = buf.cursor_line();
    let made = 0;
    let i = 0;
    while (i < n - 1) {
        if (buf.join_down(at)) { made = made + 1; i = i + 1; } else { i = n }
    };
    if (made == 0) {
        buf.msg("only one line to join");
        return ACT_CONTINUE
    };
    if (op == buf.OP_Y) {
        buf.reg_set(buf.line_at(at), true);
        return ACT_CONTINUE
    };
    if (op == buf.OP_C) {
        buf.clamp_cursor(true);
        buf.scroll_fix();
        enter_insert();
        return ACT_CONTINUE
    };
    buf.clamp_cursor(false);
    buf.scroll_fix();
    ACT_CONTINUE
};

// ===========================================================================
// g-prefixed keys
// ===========================================================================

def g_key(k: long) -> long {
    PEND_G = false;
    if (k == ord("g")) {
        if (PEND_OP != 0) { return op_motion_raw(PEND_OP, buf.M_GG) };
        buf.goto_motion(buf.M_GG, raw_count());
        return ACT_CONTINUE
    };
    if (PEND_OP != 0) {
        let op = PEND_OP;
        PEND_OP = 0;
        PCOUNT = 1;
        PCOUNT_SET = false;
        buf.msg("operator " + op_char(op) + " cancelled");
        return ACT_CONTINUE
    };
    buf.msg("unknown command: g");
    ACT_CONTINUE
};

// A key pressed while an operator is waiting.
def op_pending_key(k: long) -> long {
    let op = PEND_OP;
    if (k == ord("i") || k == ord("a")) {
        PEND_I = k;
        PEND_A = k == ord("a");
        return ACT_CONTINUE
    };
    if (k == ord("j")) { return op_join(op) };
    if ((k == ord("d") && op == buf.OP_D) ||
        (k == ord("y") && op == buf.OP_Y) ||
        (k == ord("c") && op == buf.OP_C)) {
        let n = op_count();
        PEND_OP = 0;
        buf.op_linewise(op, n);
        return after_op(op)
    };
    if (is_digit(k)) {
        COUNT = COUNT * 10 + (k - 48);
        COUNT_SET = true;
        return ACT_CONTINUE
    };
    if (k == ord("g")) { PEND_G = true; return ACT_CONTINUE };
    if (k == ord("G")) { return op_motion_raw(op, buf.M_G) };
    if (k == tui.KEY_LEFT) { return op_motion(op, buf.M_H) };
    if (k == tui.KEY_RIGHT) { return op_motion(op, buf.M_L) };
    if (k == tui.KEY_UP) { return op_motion(op, buf.M_K) };
    if (k == tui.KEY_DOWN) { return op_motion(op, buf.M_J) };
    let m = buf.motion_id(k, COUNT > 0);
    if (m != buf.M_NONE) { return op_motion(op, m) };
    // An operator followed by anything else cancels, as vi does.  vi then
    // re-reads the key as a plain command; Y has no tail call, so the key is
    // reported instead -- a documented difference, and a visible one rather
    // than a silent swallow.
    PEND_OP = 0;
    PCOUNT = 1;
    COUNT = 0;
    COUNT_SET = false;
    PCOUNT_SET = false;
    buf.msg("operator " + op_char(op) + " cancelled");
    ACT_CONTINUE
};

// ===========================================================================
// fn_feed: the one entry point
// ===========================================================================

def feed(k: long) -> long {
    if (k == tui.KEY_NONE) { return ACT_CONTINUE };
    if (MODE == COMMAND) { return command_key(k) };
    if (MODE == INSERT) {
        insert_key(k);
        return ACT_CONTINUE
    };
    if (MODE == VISUAL) {
        visual_key(k);
        return ACT_CONTINUE
    };
    if (PEND_G) { return g_key(k) };
    if (PEND_I != 0) {
        let op = PEND_OP;
        let around = PEND_A;
        PEND_I = 0;
        return op_textobj(op, around, k)
    };
    if (PEND_OP != 0) { return op_pending_key(k) };
    normal_key(k)
};

export {
    NORMAL, INSERT, VISUAL, COMMAND,
    ACT_CONTINUE, ACT_QUIT, ACT_FAIL,
    mode, mode_name, set_mode, feed, pending_op, op_char,
    // the command line, read byte at a time so a redraw in COMMAND mode
    // allocates nothing
    cmd_len, cmd_byte,
    // the key script
    script_decode, script_take, script_more, script_count, script_used,
    SCRIPT_ERR,
    // called directly by check.y, which drives the command line without
    // going through feed()
    ex, count_now
};