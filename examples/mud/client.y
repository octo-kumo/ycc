// client.y -- the MUD client: the protocol parser, the policy that chooses each
// next command, the transcript renderer, and the live terminal view.
//
// ===========================================================================
// WHY THE CLIENT PARSES BYTES AND KEEPS NAMES IN A 512-BYTE ARENA
// ===========================================================================
//
// The obvious client is `from_bytes(line.split("|"))` and a `[str]` per field.
// That is an allocation per field per command, on a thread, in a loop that runs
// for the life of a connection -- precisely the leak ORCHESTRATOR.md 2.7 warns
// about, and there is no free() to reclaim it.
//
// So: every field is read in place out of the client's own [byte; 4096] receive
// buffer, numbers are parsed with a scan (fnum below) and the few strings the
// client must KEEP -- the room name, the first item on the floor, the first item
// in the pack, the monster -- are copied into a 512-byte per-client arena at
// fixed slots.  Nothing else is kept: everything else is rendered into the
// transcript as it streams past, which is both cheaper and closer to how a real
// client redraws.
//
// ===========================================================================
// WHY THE CLIENT HAS A POLICY AND NOT A SCRIPT
// ===========================================================================
//
// A fixed script (`look`, `n`, `n`, `take torch`) would need the world to be one
// particular shape, and the transcript would then be asserting the fixture
// rather than the program.  This client reads what it has been told and chooses
// the next command from it: take what is here, drop what it is carrying, fight
// what is watching, otherwise walk through the first exit that exists.  Two
// clients running the same policy from the same seed walk the same path -- which
// is what makes the deterministic transcript reproducible -- but every command
// was chosen because the server said it was available.
//
// `sync` is in the cycle, twice around the `say`.  That is not decoration: chat is
// delivered into the recipient's pending region, which is drained at the top of
// its next reply block, so without a barrier on both sides the line would appear
// in the transcript either in this block or the next one, depending on thread
// timing.  See server.y, "sync".

// NOTE ON IMPORTS.  Every .y file here compiles on its own (the acceptance
// gate builds each one), and a module's own imports do not carry for the
// modules IT imports -- `import sockio;` does not bring in the `rnd` that
// world.y uses.  So each file names its whole closure.  See server.y.
import rnd;
import net;
import sockio;
import world;

// ---- limits (array sizes are integer literals in a type) -------------------
const MAXC = 8;          // client slots
const TSZ = 65536;       // transcript bytes per client
// The name arena: NSL slots of NSLOT bytes each, per client.  NSL * NSLOT must
// equal NN exactly -- with five slots at 128 bytes NN has to be 640, and when it
// was 512 the fifth slot ran one region past its own client and straight into the
// next client's, which surfaced as `index out of bounds` two steps into a run.
const NSL = 5;
const NN = 640;          // the name arena per client = NSL * NSLOT
const NSLOT = 128;       // and the slot size inside it
const SL_ROOM = 0;
const SL_GROUND = 1;
const SL_CARRY = 2;
const SL_MON = 3;
const SL_OTH = 4;      // who else is here: appended, not replaced

// ---- transcript layout ----------------------------------------------------
const CW = 66;           // the rule width

// Named `const` strings, not a table of literals.  A record or array LITERAL
// inside a loop body allocates on every iteration (SUGGESTIONS.md 7, measured
// at 64 bytes) and these renderers run once per protocol line; a `const` is one
// module-level binding initialised once, so `ts(c, n, DASH)` costs nothing
// however many lines go through it.

const HD = "  -- ";
const MSG = "  * ";
const STAT0 = "  hp ";
const CARRY0 = "  you carry: ";
const OTHERS0 = "  also here: ";
const ART = "  a ";
const THED = "  the ";
const SP = " ";
const COMMA = ",";
const TIMES = "x";
const EXITS0 = "  exits: ";
const FLOOR0 = "  on the floor: ";
const WATCH0 = "  watching you: ";
const NOTHING = "  (nothing)";
const MAPLBL = "  [map] ";
const ERRPFX = "server: ";
const NEWL = "
";
const DASH = "  - ";
const ROOM0 = "  [room ";
const ROOM1 = "]  ";
const UNK = "  ?? ";
const SL2 = " room";
const PLAYERS = " player(s) online";
const MAPR = 24;         // rooms, world.MAXR

// ---- per-client parsed view ----------------------------------------------
let V_PROTO: [long; 8] = [0; 8];
let V_ROOMS: [long; 8] = [0; 8];        // what the server said at login
let V_NCLI: [long; 8] = [0; 8];
let V_ROOM: [long; 8] = [0; 8];
let V_HP: [long; 8] = [0; 8];
let V_MAXHP: [long; 8] = [0; 8];
let V_COIN: [long; 8] = [0; 8];
let V_NCARRY: [long; 8] = [0; 8];
let V_TURN: [long; 8] = [0; 8];
let V_NMSG: [long; 8] = [0; 8];        // chat lines received
let V_NEX: [long; 8] = [0; 8];         // exits out of the current room
let V_EXMASK: [long; 8] = [0; 8];      // bit d set = exit d exists
let V_STEPS: [long; 8] = [0; 8];
let V_NA: [long; 8] = [0; 8];          // the name arena length
let V_SLOTLEN: [long; 40] = [0; 40];   // 8 clients x 5 slots
let V_SLOTID: [long; 40] = [0; 40];    // a count, or a monster's hp
let V_MAPROOMS: [long; 8] = [0; 8];
let V_MAPEXITS: [long; 8] = [0; 8];
let V_MAPSEEN: [long; 8] = [0; 8];
let V_MAPBAD: [long; 8] = [0; 8];      // fields that disagreed with world.y
let M_NEX: [long; 192] = [0; 192];     // client x room: exits learned from map
let M_MASK: [long; 192] = [0; 192];    // and their directions
let M_LX: [long; 192] = [0; 192];
let M_LY: [long; 192] = [0; 192];
let V_ERRS: [long; 8] = [0; 8];        // +ERR lines seen
let V_DONE: [long] = [0];              // clients finished, the rendezvous count
let V_RC: [long; 8] = [0; 8];          // each client's exit status
let V_OTHERS: [long; 8] = [0; 8];     // +ROTH lines seen since the last +ROOM
let V_MAPCMD: [long; 8] = [0; 8];      // has this client been asked for a map
let V_OTHOK: [long; 8] = [0; 8];       // may this command's reply draw +ROTH?

// arm_others: say whether the command about to be sent should render the
// `also here:` line.
//
// THIS IS THE ONE PLACE THE CLIENT SUPPRESSES SOMETHING THE SERVER SENT, and it
// is worth being explicit about why.  `+ROTH` is in every room view, including
// the one that comes back from a movement -- and whether the OTHER player is
// still in the old room when this movement is served is a genuine race between
// two workers.  Measured: 4 runs identical, the 5th differed by exactly one
// `also here:` line.  The `look` reply is not racy, because `look` is only ever
// issued straight after a `sync` barrier, so both players are provably in the
// room before either reply is built.  So the client asks "was this `look'?" and
// draws the line only then: the information is still shown, at the one point
// where it is a fact rather than a coin toss.
def arm_others(c: long, is_look: bool) -> long {
    if (is_look) { V_OTHOK[c] = 1 } else { V_OTHOK[c] = 0 };
    0
};
let V_STALLS: [long; 8] = [0; 8];      // read timeouts
let V_OVF: [long; 8] = [0; 8];         // the transcript filled up
let V_DEAD: [long; 8] = [0; 8];
let V_QUIT: [long; 8] = [0; 8];

// ---- the transcripts, one 64 KiB region per client, flat ------------------
let T: [byte; 524288] = [0; 524288];
let TLEN: [long; 8] = [0; 8];

// The run's own summary gets its OWN region rather than reusing a client's: an
// earlier version printed the summary into client 0's transcript and silently
// destroyed that client's half of the output.  It is a region, not a slot, so no
// client index is involved.
const SUM = 524288;
const SUMSZ = 65536;
let SUMBUF: [byte; 65536] = [0; 65536];
let SUMLEN: [long] = [0];

// ---- the name arenas ------------------------------------------------------
let NM: [byte; 5120] = [0; 5120];   // MAXC * NN

// ---------------------------------------------------------------------------
// transcript appends.  Flat storage indexed c * TSZ + n, because Y cannot write
// a literal for an array OF fixed arrays ([[byte; 65536]; 8] needs a size
// expression and a fixed size must be a literal) -- see the `+=` note in
// README.md, "WORKAROUNDS".
// ---------------------------------------------------------------------------
def tc(c: long, n: long, ch: long) -> long {
    // The bound is on the length WITHIN the region, not on the absolute offset.
    // Checking `c * TSZ + n < TSZ - 1` makes slot 1 look past the end before it
    // has written a single byte -- c * TSZ is already 65536 -- so every client
    // except slot 0 produced an EMPTY transcript, silently, with no overflow
    // flag either (the else branch was never reached).  One client and it looks
    // perfect; two clients and half the output is gone.
    if (n < TSZ - 1) { T[c * TSZ + n] = ch; n = n + 1 } else { V_OVF[c] = 1 };
    n
};
def ts(c: long, n: long, s: str) -> long {
    let i = 0;
    let k = n;
    while (i < len(s)) {
        if (k < TSZ - 1) { T[c * TSZ + k] = s[i]; k = k + 1 } else { V_OVF[c] = 1 };
        i = i + 1;
    };
    k
};
// Two passes, no scratch array: see sockio.obn for why (a digit buffer here cost
// 39 bytes a CALL, on every number the transcript prints).
def tn(c: long, n: long, v: long) -> long {
    if (v < 0) { n = tc(c, n, 45); v = 0 - v };
    let k = 1;
    let t = v;
    while (t >= 10) { t = t / 10; k = k + 1 };
    if (n + k < TSZ - 1) {
        let p = n + k;
        let w = v;
        while (p > n) {
            p = p - 1;
            T[c * TSZ + p] = 48 + (w % 10);
            w = w / 10;
        };
        n = n + k;
    } else {
        V_OVF[c] = 1;
    };
    n
};
def tpad(c: long, n: long, v: long, w: long) -> long {
    if (v < 0) { n = tc(c, n, 45); v = 0 - v };
    let k = 1;
    let t = v;
    while (t >= 10) { t = t / 10; k = k + 1 };
    let i = 0;
    while (i < w - k) { n = tc(c, n, 32); i = i + 1 };
    tn(c, n, v)
};
// copy a byte range of the receive buffer straight into the transcript
def tmem(c: long, n: long, src: [byte; 4096], a: long, z: long) -> long {
    let i = a;
    let k = n;
    while (i < z) {
        if (k < TSZ - 1) { T[c * TSZ + k] = src[i]; k = k + 1 } else { V_OVF[c] = 1 };
        i = i + 1;
    };
    k
};
def tnl(c: long, n: long) -> long { tc(c, n, 10) };

// ---- the summary region's appends (same discipline, its own buffer) -------
def sn(n: long, ch: long) -> long {
    if (n < SUMSZ - 1) { SUMBUF[n] = ch; n = n + 1 };
    n
};
def ss(n: long, s: str) -> long {
    let i = 0;
    let k = n;
    while (i < len(s)) { k = sn(k, s[i]); i = i + 1 };
    k
};
def sv(n: long, v: long) -> long {
    if (v < 0) { n = sn(n, 45); v = 0 - v };
    let k = 1;
    let t = v;
    while (t >= 10) { t = t / 10; k = k + 1 };
    if (n + k < SUMSZ - 1) {
        let p = n + k;
        let w = v;
        while (p > n) {
            p = p - 1;
            SUMBUF[p] = 48 + (w % 10);
            w = w / 10;
        };
        n = n + k;
    };
    n
};

// right-align in `w` columns, for a table of numbers
def svpad(n: long, v: long, w: long) -> long {
    if (v < 0) { n = sn(n, 45); v = 0 - v };
    let k = 1;
    let t = v;
    while (t >= 10) { t = t / 10; k = k + 1 };
    let i = 0;
    while (i < w - k) { n = sn(n, 32); i = i + 1 };
    sv(n, v)
};

// ---------------------------------------------------------------------------
// the name arena
// ---------------------------------------------------------------------------
def slot_base(c: long, k: long) -> long { c * NN + k * NSLOT };

def slot_clear(c: long, k: long) -> long {
    V_SLOTLEN[c * NSL + k] = 0;
    V_SLOTID[c * NSL + k] = 0 - 1;
    0
};

// Copy [a, z) of the receive buffer into a slot, truncated at the slot size.
def slot_put(c: long, k: long, src: [byte; 4096], a: long, z: long, id: long) -> long {
    let base = slot_base(c, k);
    let i = a;
    let n = 0;
    while (i < z && n < NSLOT - 1) {
        NM[base + n] = src[i];
        n = n + 1;
        i = i + 1;
    };
    V_SLOTLEN[c * NSL + k] = n;
    V_SLOTID[c * NSL + k] = id;
    n
};

// A second +RITEM for the SAME item kind adds to the slot's count rather than
// overwriting it, so the renderer can show "brass torch x2" after the server sent
// two separate one-quantity lines for two instances of that kind.
def slot_bump(c: long, k: long, q: long) -> long {
    V_SLOTID[c * NSL + k] = V_SLOTID[c * NSL + k] + q;
    0
};

def slot_len(c: long, k: long) -> long { V_SLOTLEN[c * NSL + k] };
def slot_id(c: long, k: long) -> long { V_SLOTID[c * NSL + k] };

// slot text into the transcript
def tslot(c: long, n: long, k: long) -> long {
    let base = slot_base(c, k);
    let i = 0;
    let ln = V_SLOTLEN[c * NSL + k];
    while (i < ln) { n = tc(c, n, NM[base + i]); i = i + 1 };
    n
};

// ---------------------------------------------------------------------------
// printing a client's transcript
// ---------------------------------------------------------------------------
//
// One write(2) per client, at the end, from the flat region.  Not `puts` of a
// str: T is already bytes and this way the transcript is never a str at all.

def emit(c: long) -> long {
    syscall(1, 1, &T[c * TSZ], TLEN[c])
};

// one write(1) of the run's own summary
def emit_summary() -> long {
    syscall(1, 1, &SUMBUF[0], SUMLEN[0])
};

// The per-client header: the rule, the player's name, and its slot.
def banner(c: long, n: long, who: str, slot: long, of: long) -> long {
    n = ts(c, n, "================================================================\n");
    n = ts(c, n, "  ");
    n = ts(c, n, who);
    n = ts(c, n, "  --  client ");
    n = tn(c, n, slot);
    n = ts(c, n, " of ");
    n = tn(c, n, of);
    n = tnl(c, n);
    n = ts(c, n, "================================================================\n");
    n
};

// ---------------------------------------------------------------------------
// in-place field reads: fnum reads field k of the byte range [a, z), where the
// fields are separated by '|'.  -1 when the field is absent or not a number.
// ---------------------------------------------------------------------------
def fnum(b: [byte; 4096], a: long, z: long, k: long) -> long {
    let i = a;
    let f = 0;
    while (i < z && f < k) {
        if (b[i] == 124) { f = f + 1 };
        i = i + 1;
    };
    let v = 0;
    let seen = 0;
    let ok = i < z;
    while (i < z && b[i] != 124 && ok) {
        let ch = b[i];
        if (ch >= 48 && ch <= 57) {
            v = v * 10 + (ch - 48);
            seen = seen + 1;
        } else {
            ok = false;
        };
        i = i + 1;
    };
    if (seen == 0 || !ok) { 0 - 1 } else { v }
};

// the byte range of field k, as an offset pair packed into one long:
// start * 4096 + end.  Packed rather than returned as an array because returning
// a pair would allocate one.
def frange(b: [byte; 4096], a: long, z: long, k: long) -> long {
    let i = a;
    let f = 0;
    while (i < z && f < k) {
        if (b[i] == 124) { f = f + 1 };
        i = i + 1;
    };
    let s = i;
    while (i < z && b[i] != 124) { i = i + 1 };
    s * 4096 + i
};

def has_prefix(b: [byte; 4096], a: long, z: long, p: str) -> bool {
    let ok = z - a >= len(p);
    let i = 0;
    while (i < len(p) && ok) {
        if (b[a + i] != p[i]) { ok = false };
        i = i + 1;
    };
    ok
};

// is_end: the `+END` terminator, so a reader knows when a reply block is done
// reset: clear one client's slot before a run.  Every array this client owns is
// zeroed here, so a second run over the same slots cannot inherit the first run's
// view -- which matters because --bench drives many connections through the same
// eight slots.
def reset(c: long, who: str, slot: long, of: long) -> long {
    V_ROOM[c] = 0 - 1;
    V_ROOMS[c] = 0;
    V_HP[c] = 0;
    V_MAXHP[c] = 0;
    V_COIN[c] = 0;
    V_NCARRY[c] = 0;
    V_TURN[c] = 0;
    V_NMSG[c] = 0;
    V_NEX[c] = 0;
    V_EXMASK[c] = 0;
    V_STEPS[c] = 0;
    V_PROTO[c] = 0;
    V_NCLI[c] = 0;
    V_NA[c] = 0;
    V_MAPROOMS[c] = 0;
    V_MAPEXITS[c] = 0;
    V_MAPSEEN[c] = 0;
    V_MAPBAD[c] = 0;
    V_ERRS[c] = 0;
    V_STALLS[c] = 0;
    V_OVF[c] = 0;
    V_QUIT[c] = 0;
    V_OTHERS[c] = 0;
    V_OTHOK[c] = 0;
    V_RC[c] = 0;
    let k = 0;
    while (k < NSL) { slot_clear(c, k); k = k + 1 };
    let i = 0;
    while (i < MAPR) {
        M_NEX[c * MAPR + i] = 0;
        M_MASK[c * MAPR + i] = 0;
        M_LX[c * MAPR + i] = 0;
        M_LY[c * MAPR + i] = 0;
        i = i + 1;
    };
    TLEN[c] = banner(c, 0, who, slot, of);
    0
};

def is_end(b: [byte; 4096], a: long, z: long) -> bool {
    has_prefix(b, a, z, "+END")
};

// tcmd: a slot's text into a COMMAND buffer (not the transcript).  The client
// has to be able to say `take brass torch`, and the name it knows is in the
// arena -- this copies it into a [byte; 4096] the driver already owns.
def tcmd(buf: [byte; 4096], c: long, n: long, k: long) -> long {
    let base = slot_base(c, k);
    let i = 0;
    let ln = V_SLOTLEN[c * NSL + k];
    while (i < ln) {
        if (n < 4095) { buf[n] = NM[base + i]; n = n + 1 };
        i = i + 1;
    };
    n
};

export { MAXC, TSZ, NN, NSLOT, NSL, CW, SL_ROOM, SL_GROUND, SL_CARRY, SL_MON, SL_OTH,
         T, TLEN, NM, V_ROOM, V_ROOMS, V_HP, V_MAXHP, V_COIN, V_NCARRY,
         V_TURN, V_NMSG, V_NEX, V_EXMASK, V_STEPS, V_PROTO, V_NCLI, V_MAPROOMS,
         V_MAPEXITS, V_MAPSEEN, V_MAPBAD, M_NEX, M_MASK, M_LX, M_LY, V_ERRS,
         V_STALLS, V_OVF, V_DEAD, V_QUIT, V_SLOTLEN, V_SLOTID,
         V_DONE, V_RC, V_OTHERS, V_OTHOK, arm_others,
         tc, ts, tn, tpad, tmem, tnl, tslot, slot_len, slot_id, slot_put, slot_clear,
         emit, emit_summary, banner, is_end, tcmd, reset, sn, ss, sv, svpad,
         SUMBUF, SUMSZ, SUMLEN,
         slot_bump,
         fnum, frange, has_prefix };

// ===========================================================================
// THE RENDERERS
// ===========================================================================
//
// Every branch appends SOMETHING for every protocol tag: a transcript line that
// renders as nothing is how a protocol bug hides.  The `who` argument is unused
// except in the banner and is kept off the signature for the same reason -- one
// fewer thing for the parser and the renderer to disagree about.


// ---- transcript layout ----------------------------------------------------
const CW = 66;           // the rule width

// Named `const` strings, not a table of literals.  A record or array LITERAL
// inside a loop body allocates on every iteration (SUGGESTIONS.md 7, measured
// at 64 bytes) and these renderers run once per protocol line; a `const` is one
// module-level binding initialised once, so `ts(c, n, DASH)` costs nothing
// however many lines go through it.

const RULE = "================================================================\n";
const HD = "  -- ";
const MSG = "  * ";
const STAT0 = "  hp ";
const CARRY0 = "  you carry: ";
const OTHERS0 = "  also here: ";
const ART = "  a ";
const THED = "  the ";
const SP = " ";
const COMMA = ",";
const TIMES = "x";
const EXITS0 = "  exits: ";
const FLOOR0 = "  on the floor: ";
const WATCH0 = "  watching you: ";
const NOTHING = "  (nothing)";
const MAPLBL = "  [map] ";
const ERRPFX = "server: ";
const NEWL = "
";
const DASH = "  - ";
const ROOM0 = "  [room ";
const ROOM1 = "]  ";
const UNK = "  ?? ";
const SL2 = " room";
const PLAYERS = " player(s) online";

def rule_line(c: long, n: long) -> long {
    n = ts(c, n, HD);
    n
};

// room header: the name, the id, and the direction letters, right-aligned in
// their own column so a walk down a corridor reads as a column.
def draw_room(c: long, n: long) -> long {
    n = ts(c, n, HD);
    n = tslot(c, n, SL_ROOM);
    n = ts(c, n, "  [room ");
    n = tn(c, n, V_ROOM[c]);
    n = ts(c, n, "]");
    // One fixed column per compass direction, in N E S W order, each holding the
    // DIRECTION LETTER when there is an exit and a dot when there is not -- so
    // the four columns line up down a whole transcript and a reader can see at a
    // glance which way the walk went.  A bare 1..4 index here was unreadable.
    let d = 0;
    while (d < 4) {
        if ((V_EXMASK[c] & (1 << d)) != 0) {
            n = ts(c, n, SP);
            n = ts(c, n, world.dir_abbr(d));
        } else {
            n = ts(c, n, " .");
        };
        n = ts(c, n, SP);
        d = d + 1;
    };
    n = ts(c, n, " ");
    let i = 0;
    while (i < CW - 30) { n = ts(c, n, SP); i = i + 1 };
    n = ts(c, n, "exits ");
    n = tn(c, n, V_NEX[c]);
    tnl(c, n)
};

def draw_desc(c: long, n: long, rx: [byte; 4096], a: long, z: long) -> long {
    n = ts(c, n, "  ");
    n = tmem(c, n, rx, a, z);
    n = tnl(c, n);
    n
};

// One floor or carried item, from the +RITEM / +CARRY fields, drawn where the
// server put it.  The count is only shown when it is above one, because "x1" is
// noise and its absence means the same thing.
def draw_item(c: long, n: long, rx: [byte; 4096], a: long, z: long) -> long {
    n = ts(c, n, FLOOR0);
    let f = frange(rx, a, z, 2);
    n = tmem(c, n, rx, f / 4096, f % 4096);
    let q = fnum(rx, a, z, 3);
    if (q > 1) {
        n = ts(c, n, SP);
        n = ts(c, n, TIMES);
        n = tn(c, n, q);
    };
    n = ts(c, n, "     instance ");
    n = tn(c, n, fnum(rx, a, z, 0));
    tnl(c, n)
};

// The same for a carried item, under its own heading.
def draw_item2(c: long, n: long, rx: [byte; 4096], a: long, z: long) -> long {
    n = ts(c, n, CARRY0);
    let f = frange(rx, a, z, 2);
    n = tmem(c, n, rx, f / 4096, f % 4096);
    let q = fnum(rx, a, z, 3);
    if (q > 1) {
        n = ts(c, n, SP);
        n = ts(c, n, TIMES);
        n = tn(c, n, q);
    };
    n = ts(c, n, "     instance ");
    n = tn(c, n, fnum(rx, a, z, 0));
    tnl(c, n)
};

def draw_others(c: long, n: long) -> long {
    n = ts(c, n, OTHERS0);
    n = tslot(c, n, SL_OTH);
    n = tnl(c, n);
    n
};

def draw_mon(c: long, n: long) -> long {
    n = ts(c, n, WATCH0);
    if (slot_len(c, SL_MON) == 0) {
        n = ts(c, n, NOTHING);
    } else {
        n = tslot(c, n, SL_MON);
        n = ts(c, n, "  (");
        n = tn(c, n, slot_id(c, SL_MON));
        n = ts(c, n, " hp)");
    };
    n = tnl(c, n);
    n
};

// the status line every block ends with: hp, coins, what is carried, the turn
// count, and how many messages have arrived.  `msgs` is the number of PENDING
// chat lines this client has been handed -- it is the number property check (d)
// asserts on, and it is what proves the two-way chat path works at all.
def draw_stat(c: long, n: long) -> long {
    n = ts(c, n, STAT0);
    n = tn(c, n, V_HP[c]);
    n = ts(c, n, "/");
    n = tn(c, n, V_MAXHP[c]);
    n = ts(c, n, "  coin ");
    n = tn(c, n, V_COIN[c]);
    n = ts(c, n, "  turn ");
    n = tn(c, n, V_TURN[c]);
    n = ts(c, n, "  msgs ");
    n = tn(c, n, V_NMSG[c]);
    n = tnl(c, n);
    n
};

// ---------------------------------------------------------------------------
// one protocol line into the transcript
// ---------------------------------------------------------------------------
// Returns the new length.  Every branch appends SOMETHING for every tag, because
// a transcript line that renders as nothing is how a protocol bug hides.

def render_line(c: long, n: long, rx: [byte; 4096], a: long, z: long, who: str) -> long {
    if (has_prefix(rx, a, z, "+MSG ")) {
        n = ts(c, n, MSG);
        n = tmem(c, n, rx, a + 5, z);
        n = tnl(c, n);
    } else if (has_prefix(rx, a, z, "+ROOM ")) {
        // The name and the id arrive here; the header itself is drawn at
        // +REXITS, which is the last line that carries the directions.  Drawing
        // it here showed the exit columns BEFORE the server had sent them, so
        // every room header read ". . . .".
        let f = frange(rx, a + 6, z, 1);
        slot_put(c, SL_ROOM, rx, f / 4096, f % 4096, 0);
        V_ROOM[c] = fnum(rx, a + 6, z, 0);
        V_NEX[c] = 0;
        V_EXMASK[c] = 0;
        V_OTHERS[c] = 0;
        slot_clear(c, SL_GROUND);
        slot_clear(c, SL_OTH);
        slot_clear(c, SL_MON);
    } else if (has_prefix(rx, a, z, "+RDESC ")) {
        n = draw_desc(c, n, rx, a + 7, z);
    } else if (has_prefix(rx, a, z, "+REXITS ")) {
        let i = a + 8;
        let nex = 0;
        while (i < z) {
            let ch = rx[i];
            // 'n'=110 'e'=101 's'=115 'w'=119 -- there are no character literals
            // in Y, so the direction letters are matched as bytes
            if (ch == 110) { V_EXMASK[c] = V_EXMASK[c] | 1; nex = nex + 1 };
            if (ch == 101) { V_EXMASK[c] = V_EXMASK[c] | 2; nex = nex + 1 };
            if (ch == 115) { V_EXMASK[c] = V_EXMASK[c] | 4; nex = nex + 1 };
            if (ch == 119) { V_EXMASK[c] = V_EXMASK[c] | 8; nex = nex + 1 };
            i = i + 1;
        };
        V_NEX[c] = nex;
        n = draw_room(c, n);
    } else if (has_prefix(rx, a, z, "+RITEM ")) {
        // One line drawn per line sent, exactly as the server wrote it -- three
        // instances of three different items are three lines, not one line with
        // three quantities summed into it.  The SLOT holds only the first item,
        // which is what the policy takes.
        if (rx[a + 7] == 45) {
            slot_clear(c, SL_GROUND);
            n = ts(c, n, FLOOR0);
            n = ts(c, n, NOTHING);
            n = tnl(c, n);
        } else {
            if (slot_len(c, SL_GROUND) == 0) {
                let q = fnum(rx, a + 7, z, 3);
                let f = frange(rx, a + 7, z, 2);
                slot_put(c, SL_GROUND, rx, f / 4096, f % 4096, q);
            };
            n = draw_item(c, n, rx, a + 7, z);
        };
    } else if (has_prefix(rx, a, z, "+ROTH ")) {
        // counted ALWAYS (the count is what property check (b) asserts on) but
        // drawn only on a `look` -- see arm_others
        V_OTHERS[c] = V_OTHERS[c] + 1;
        slot_put(c, SL_OTH, rx, a + 6, z, 0);
        if (V_OTHOK[c] == 1) { n = draw_others(c, n) };
    } else if (has_prefix(rx, a, z, "+RMON ")) {
        let f = frange(rx, a + 6, z, 1);
        let hp = fnum(rx, a + 6, z, 2);
        slot_put(c, SL_MON, rx, f / 4096, f % 4096, hp);
        n = draw_mon(c, n);
    } else if (has_prefix(rx, a, z, "+CARRY ")) {
        // The server sends a single "+CARRY -" for an empty pack, so the dash is
        // a placeholder and not an item: drawing it produced the nonsense line
        // "you carry: instance -1".
        if (rx[a + 7] == 45) {
            slot_clear(c, SL_CARRY);
            n = ts(c, n, CARRY0);
            n = ts(c, n, NOTHING);
            n = tnl(c, n);
        } else {
            if (slot_len(c, SL_CARRY) == 0) {
                let q = fnum(rx, a + 7, z, 3);
                let f = frange(rx, a + 7, z, 2);
                slot_put(c, SL_CARRY, rx, f / 4096, f % 4096, q);
            };
            n = draw_item2(c, n, rx, a + 7, z);
        };
    } else if (has_prefix(rx, a, z, "+STAT ")) {
        V_HP[c] = fnum(rx, a + 6, z, 0);
        V_MAXHP[c] = fnum(rx, a + 6, z, 1);
        V_COIN[c] = fnum(rx, a + 6, z, 2);
        V_NCARRY[c] = fnum(rx, a + 6, z, 3);
        V_TURN[c] = fnum(rx, a + 6, z, 4);
        V_NMSG[c] = fnum(rx, a + 6, z, 6);
        n = draw_stat(c, n);
    } else if (has_prefix(rx, a, z, "+ERR ")) {
        V_ERRS[c] = V_ERRS[c] + 1;
        n = ts(c, n, MSG);
        n = ts(c, n, ERRPFX);
        n = tmem(c, n, rx, a + 5, z);
        n = tnl(c, n);
    } else if (has_prefix(rx, a, z, "+BYE ")) {
        V_QUIT[c] = 1;
    } else if (has_prefix(rx, a, z, "+HELLO ")) {
        V_PROTO[c] = fnum(rx, a + 7, z, 0);
        V_ROOMS[c] = fnum(rx, a + 7, z, 1);
        V_NCLI[c] = fnum(rx, a + 7, z, 2);
    } else if (has_prefix(rx, a, z, "+MAP ")) {
        V_MAPROOMS[c] = fnum(rx, a + 5, z, 0);
        V_MAPEXITS[c] = fnum(rx, a + 5, z, 1);
    } else if (has_prefix(rx, a, z, "+MR ")) {
        let r = fnum(rx, a + 4, z, 0);
        let nex = fnum(rx, a + 4, z, 2);
        let mask = 0;
        // field 3 is the comma-joined direction list
        let fs = frange(rx, a + 4, z, 3);
        let i = fs / 4096;
        let fz = fs % 4096;
        while (i < fz) {
            let ch = rx[i];
            if (ch == 110) { mask = mask | 1 };
            if (ch == 101) { mask = mask | 2 };
            if (ch == 115) { mask = mask | 4 };
            if (ch == 119) { mask = mask | 8 };
            i = i + 1;
        };
        if (r >= 0 && r < MAPR) {
            M_NEX[c * MAPR + r] = nex;
            M_MASK[c * MAPR + r] = mask;
            M_LX[c * MAPR + r] = fnum(rx, a + 4, z, 4);
            M_LY[c * MAPR + r] = fnum(rx, a + 4, z, 5);
            V_MAPSEEN[c] = V_MAPSEEN[c] + 1;
        } else {
            V_MAPBAD[c] = V_MAPBAD[c] + 1;
        };
    } else if (has_prefix(rx, a, z, "+WHO ")) {
        n = ts(c, n, MSG);
        n = tn(c, n, fnum(rx, a + 5, z, 0));
        n = ts(c, n, PLAYERS);
        n = tnl(c, n);
    } else if (has_prefix(rx, a, z, "+WHOW ")) {
        let f1 = frange(rx, a + 6, z, 0);
        n = ts(c, n, DASH);
        n = tmem(c, n, rx, f1 / 4096, f1 % 4096);
        n = ts(c, n, "  room ");
        n = tn(c, n, fnum(rx, a + 6, z, 1));
        n = tnl(c, n);
    } else if (has_prefix(rx, a, z, "+MEND")) {
        n = ts(c, n, MAPLBL);
        n = tn(c, n, V_MAPSEEN[c]);
        n = ts(c, n, " rooms, ");
        n = tn(c, n, V_MAPEXITS[c]);
        n = ts(c, n, " exits");
        n = tnl(c, n);
    } else if (has_prefix(rx, a, z, "+END")) {
        0                                    // the block terminator draws nothing
    } else {
        n = ts(c, n, UNK);
        n = tmem(c, n, rx, a, z);
        n = tnl(c, n);
    };
    n
};
