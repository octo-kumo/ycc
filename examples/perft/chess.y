// chess.y -- a complete legal chess move generator, make/unmake, perft, and a
// validating FEN reader.  The engine half of `perft`; `perft.y` drives it.
//
// ===========================================================================
// WHY THIS FILE IS WRITTEN THE WAY IT IS
// ===========================================================================
//
// * THE BOARD IS A 10x12 MAILBOX.  Square numbers run 21..98 (a8 = 21,
//   h1 = 98) with a two-square border of the sentinel OFF (255) around them,
//   so `sq` is a plain index and *no offset can leave the array*: the worst
//   single step is a knight from a8 (21 - 21 = 0) or from h1 (98 + 21 = 119),
//   both still inside.  A ray stops at the first non-empty square, and the
//   border is not empty, so a ray never steps twice off the board.  That is
//   why there is not one bounds check in the generator: the shape of the
//   board removes the whole class of bug (and the whole cost) at a stroke.
//
// * PIECES ARE 0 (empty), 1..6 (white P N B R Q K) and 9..14 (the same six
//   in black).  So `pc & 8` is the colour and `pc & 7` the kind, one mask
//   each, and "black pawn" is 9 rather than a second table.
//
// * A MOVE IS ONE PACKED LONG -- from | to<<8 | flag<<16 | promo<<24 -- never a
//   record, never an array.  `make` answers the captured piece and `unmake`
//   takes it back, so nothing has to be remembered between them and nothing
//   is allocated: the whole search runs out of two fixed buffers per Pos.
//
// * LEGALITY IS "MAKE IT, LOOK AT THE KING, PUT IT BACK".  Pseudo-legal
//   generation with a king-safety filter is the formulation that cannot get
//   pins, discovered checks, en-passant pins and castling through a wrong
//   square wrong at the same time -- every one of those is a rule about the
//   position *after* the move, so testing the position after the move is the
//   direct way to say it.  Castling is the one exception, because "the king
//   may not start in check, or pass through an attacked square, or land on
//   one" needs the attack scan on the board *before* the move; see gen_castle.
//
// * NOTHING IN THE SEARCH ALLOCATES.  The heap is an arena and nothing is ever
//   freed, so a literal or a string inside perft would
//   leak per node and a 5-million-node search would die under the 3.5 GiB
//   cap.  Every buffer here is a fixed array inside a Pos, allocated once.

// ── the board ─────────────────────────────────────────────────────────────

// The border sentinel.  255 is not a legal piece code (pieces are 0..14), and
// it is deliberately NOT 0: a ray must stop on it, and a knight landing on it
// must be ignored.
const OFF: long = 255;

// A move is one packed long: from | to<<8 | flag<<16 | promo<<24.
const F_QUIET: long = 0;      // a step, or a capture -- make() reads the target, so the two need no flag
const F_DPUSH: long = 1;      // a double pawn push: sets the en-passant square
const F_EPA: long = 2;        // en passant: the captured pawn is not on `to`
const F_CK: long = 3;         // castle king side: the rook moves too
const F_CQ: long = 4;         // castle queen side: the rook moves too
const F_PROMO: long = 5;      // promotion: `promo << 24` is the new piece kind

// Castling rights, one bit each.
const CR_WK: long = 1;        // white, king side  (h1 rook)
const CR_WQ: long = 2;        // white, queen side (a1 rook)
const CR_BK: long = 4;        // black, king side  (h8 rook)
const CR_BQ: long = 8;        // black, queen side (a8 rook)

// The per-level move region.  256 is a power of two and no legal position has
// more than 218 moves, so `base + i` costs an add and the level index is
// `base >> 8`.  MAXDEPTH (below) caps the depth so the buffer cannot be walked
// off the end -- it is a check the driver turns into a message, never a trap.
const MVSTRIDE: long = 256;

// The 8 ray directions: 0..3 orthogonal (E W S N), 4..7 diagonal.
let D8: [long; 8] = [1, -1, 10, -10, 9, -9, 11, -11];
// The 8 knight jumps.
let KN: [long; 8] = [21, 19, 12, 8, -8, -12, -19, -21];
// The 8 king steps: one square, so they sit just inside the border -- every one
// of them from a real square is still a valid index.
let KG: [long; 8] = [11, 9, 10, 1, -1, -10, -9, -11];

// One search position: the board, the per-level move scratch, and the state.
// `bd`, `mv`, `ksq`, `oe` and `oc` are all fixed arrays, so a Pos is one
// allocation and copying one is five small memcpys -- which is why the
// threaded driver can hand every worker its own Pos (perft.y).
//
//   side   0 = white to move, 8 = black to move (the colour bit, so the
//          generator's `(pc & 8) == p.side` needs no conversion)
//   castle the four CR_ bits
//   ep     the en-passant target square, or -1
//   ksq    each side's king square, maintained by make/unmake so the legality
//          test never scans the board for a king
//   oe/oc  the ep and castling words as they were when the level's move was
//          made, indexed by `base >> 8`: unmake restores them
type Pos = {
    bd: [byte; 120],
    mv: [long; 2560],
    ksq: [long; 2],
    oe: [long; 12],
    oc: [long; 12],
    side: long,
    castle: long,
    ep: long
};

def new_pos() -> Pos {
    let p: Pos = {
        bd: ['\xff'; 120],
        mv: [0; 2560],
        ksq: [0; 2],
        oe: [0; 12],
        oc: [0; 12],
        side: 0,
        castle: 0,
        ep: -1
    };
    let sq = 0;
    let stop = false;
    while (stop == false) {
        if (sq > 119) {
            stop = true
        } else {
            if (sq >= 21 && sq <= 98 && (sq - 21) % 10 < 8) { p.bd[sq] = 0 };
            sq = sq + 1
        }
    };
    p
};

// pack(f, t, flag, promo) -> long.  One move, one machine word.
def pack(f: long, t: long, flag: long, promo: long) -> long {
    f | (t << 8) | (flag << 16) | (promo << 24)
};

// Is `sq` one of the 64 squares a piece can stand on?  Used only by the FEN
// reader and the tests; the generator never needs it, because of the border.
def real_sq(sq: long) -> bool {
    sq >= 21 && sq <= 98 && (sq - 21) % 10 < 8
};

// The pawn's forward step: white climbs the board (-10), black descends (+10).
def fwd_of(side: long) -> long {
    if (side == 0) { -10 } else { 10 }
};

// cmask(sq) -> the castling rights that SURVIVE a piece touching `sq`, as a
// four-bit mask; the caller ANDs two of these into p.castle.  A king home keeps
// only the other side's pair (e1 -> 12, e8 -> 3), a rook corner keeps all but
// its own rook's right (h1 -> 14, a1 -> 13, h8 -> 11, a8 -> 7), and every
// other square keeps everything (15).
//
// It is written as survivors rather than as "rights destroyed" because that
// inversion is invisible in review and fatal in play: with `castle & cmask(sq)`
// and a destroy-list, 1.Ra1-b1 left the position holding the white QUEENSIDE
// right and no black rights at all (2 instead of 13), and Kiwipete came out 18
// nodes short at depth 2 with no diagnostic.  The start position hid it for a
// while, because its a1 and h1 rooks are boxed in by their own knights and can
// never move at all.
//
// Written as comparisons rather than a table so there is no init order to get
// wrong -- the engine has no setup step at all, which is why a Pos can be
// built at the top of a thread's first turn.
def cmask(sq: long) -> long {
    if (sq == 95) { 12 } else if (sq == 25) { 3 }
    else if (sq == 98) { 14 } else if (sq == 91) { 13 }
    else if (sq == 28) { 11 } else if (sq == 21) { 7 } else { 15 }
};

// ── attacks ───────────────────────────────────────────────────────────────

// attacked(bd, sq, by) -> is `sq` attacked by a piece of colour `by`?
//
// `by` is 0 (white) or 8 (black).  Scan outward from the square rather than
// generating the mover's moves: for a king-safety test the square is the only
// thing that matters, and a ray stops at the first piece, so the scan is O(1)
// in the common case (the first neighbour is the attacker) and never walks a
// whole ray that has nothing to do with the answer.
def attacked(bd: [byte; 120], sq: long, by: long) -> bool {
    let nk = 2 + by;
    let kg = 6 + by;
    let pw = 1 + by;
    // The two squares a `by` pawn could stand on to hit sq.  A white pawn
    // moves to -10, so it attacks from -9 and -11; black is the mirror.
    let pa = sq + if (by == 0) { 9 } else { -9 };
    let pb = sq + if (by == 0) { 11 } else { -11 };
    if (bd[pa] == pw) { return true };
    if (bd[pb] == pw) { return true };
    let i = 0;
    while (i < 8) {
        if (bd[sq + KN[i]] == nk) { return true };
        i = i + 1
    };
    i = 0;
    while (i < 8) {
        if (bd[sq + KG[i]] == kg) { return true };
        i = i + 1
    };
    let d = 0;
    while (d < 8) {
        let s = sq + D8[d];
        let oc = bd[s];
        let go = true;
        let want = if (d < 4) { 4 } else { 3 };
        while (go) {
            if (oc == 0) {
                s = s + D8[d];
                oc = bd[s]
            } else {
                if (oc != OFF && (oc & 8) == by
                    && ((oc & 7) == want || (oc & 7) == 5)) { return true };
                go = false
            }
        };
        d = d + 1
    };
    false
};

// ── make / unmake ─────────────────────────────────────────────────────────

// make(p, m, base) -> the captured piece.
//
// `base` is the move region of this level, so `base >> 8` indexes the undo
// words; a deeper level has a bigger base and cannot disturb them.
def make(p: Pos, m: long, base: long) -> long {
    let bd = p.bd;
    let from = m & 255;
    let to = (m >> 8) & 255;
    let flag = (m >> 16) & 255;
    let promo = (m >> 24) & 15;
    let pc = bd[from];
    let cap = bd[to];
    let lev = base >> 8;
    p.oe[lev] = p.ep;
    p.oc[lev] = p.castle;
    if (flag == F_EPA) {
        let v = to - fwd_of(p.side);
        cap = bd[v];
        bd[v] = 0
    };
    bd[from] = 0;
    if (flag == F_PROMO) { bd[to] = promo + p.side } else { bd[to] = pc };
    if (flag == F_DPUSH) { p.ep = (from + to) / 2 } else { p.ep = -1 };
    p.castle = p.castle & cmask(from) & cmask(to);
    if ((pc & 7) == 6) {
        p.ksq[p.side / 8] = to;
        // The rook rides along, and both halves say it in terms of `from`, which
        // is the only form that cannot be written backwards: king side the rook
        // steps from+3 -> from+1 (h1 -> f1), queen side from-4 -> from-1
        // (a1 -> d1).  The first version of this said bd[to+1] = bd[to-1],
        // which copies f1 ONTO h1 -- so castling quietly deleted the rook, and
        // the h1 rook's own moves vanished from every position that could
        // castle.  Nothing trapped; the count was merely short by two.
        if (flag == F_CK) { bd[from + 1] = bd[from + 3]; bd[from + 3] = 0 };
        if (flag == F_CQ) { bd[from - 1] = bd[from - 4]; bd[from - 4] = 0 }
    };
    // The side to move belongs to the POSITION, so make() is what flips it --
    // everything downstream (gen_all, perft, the legality test) then just reads
    // p.side and never has to know whose move it was.  Forgetting this line is
    // silent: the generator happily produces the mover's moves a second time,
    // and the start position answers 445 at depth 2 instead of 400.
    p.side = p.side ^ 8;
    cap
};

// unmake(p, m, base, cap) -- exactly make() backwards.  The moving piece is
// recovered from the move word, which matters for a promotion: the board holds
// the queen, the pawn has to go back.
def unmake(p: Pos, m: long, base: long, cap: long) -> void {
    let bd = p.bd;
    // make() left p.side holding the opponent, who was the side to move in the
    // position this move came from; flip first, because everything below -- the
    // en-passant victim square, the promotion's pawn, the king's index -- is
    // the MOVER's colour.
    p.side = p.side ^ 8;
    let from = m & 255;
    let to = (m >> 8) & 255;
    let flag = (m >> 16) & 255;
    let lev = base >> 8;
    let pc = bd[to];
    // The rook goes home again: the MIRROR of make's two lines, not the same
    // two lines.  make() copies the corner onto the home square; unmake() copies
    // the home square back onto the corner.  Writing make's version here reads
    // an already-emptied corner and deletes the rook for good -- which is why
    // the h1 rook's moves vanished from every position with castling rights,
    // and only from those.
    if (flag == F_CK) { bd[from + 3] = bd[from + 1]; bd[from + 1] = 0 };
    if (flag == F_CQ) { bd[from - 4] = bd[from - 1]; bd[from - 1] = 0 };
    if (flag == F_PROMO) { bd[from] = 1 + p.side } else { bd[from] = pc };
    if ((pc & 7) == 6) { p.ksq[p.side / 8] = from };
    if (flag == F_EPA) { bd[to - fwd_of(p.side)] = cap; bd[to] = 0 } else { bd[to] = cap };
    p.ep = p.oe[lev];
    p.castle = p.oc[lev]
}

// ── move generation ───────────────────────────────────────────────────────

// try_move(p, base, n, m) -> n or n+1: play `m`, and keep it only if `m`'s own
// king is not attacked afterwards.  This one function is where pins, discovered
// checks and en-passant pins are all handled -- there is nothing else in the
// file that knows they exist.
def try_move(p: Pos, base: long, n: long, m: long) -> long {
    let me = p.side;
    let cap = make(p, m, base);
    // The king's square is read AFTER make(), and indexed by the MOVER's colour
    // -- saved as `me` first, because make() hands p.side to the opponent, and
    // because make() is also what moved the king.  Reading the square BEFORE the
    // move, as an earlier version of this did, tests where the king came FROM:
    // every move that walks the king into check is then legal.
    let bad = attacked(p.bd, p.ksq[me / 8], me ^ 8);
    unmake(p, m, base, cap);
    if (bad) { n } else { p.mv[base + n] = m; n + 1 }
}

// Can `to` be captured on?  Empty is fine, an enemy piece is fine, and the
// enemy KING is not: capturing it cannot happen in a legal position (the FEN
// reader refuses one where it could), and generating it would let a corrupt
// position walk off into nonsense instead of being caught.
def takeable(bd: [byte; 120], to: long, foe: long) -> bool {
    let pc = bd[to];
    pc == 0 || (pc != OFF && (pc & 8) == foe && (pc & 7) != 6)
}

// gen_leaper(p, base, n, sq, kind, foe, jumps) -- the knight and the king:
// eight jumps, no sliding.  `jumps` is KN or KG, so the two share one loop --
// and they are genuinely different arrays, not one derived from the other.
def gen_leaper(p: Pos, base: long, n: long, sq: long, kind: long, foe: long, jumps: [long; 8]) -> long {
    let bd = p.bd;
    let i = 0;
    while (i < 8) {
        let to = sq + jumps[i];
        if (takeable(bd, to, foe)) {
            n = try_move(p, base, n, pack(sq, to, F_QUIET, 0))
        };
        i = i + 1
    };
    n
}

// gen_slider(p, base, n, sq, kind, foe) -- bishop, rook, queen.  Indices 0..3
// of D8 are orthogonal (rook, queen) and 4..7 diagonal (bishop, queen), so
// one loop covers all three with a range rather than three near-copies.
def gen_slider(p: Pos, base: long, n: long, sq: long, kind: long, foe: long) -> long {
    let bd = p.bd;
    let lo = if (kind == 3) { 4 } else { 0 };
    let hi = if (kind == 4) { 4 } else { 8 };
    let d = lo;
    while (d < hi) {
        let to = sq + D8[d];
        let oc = bd[to];
        let go = true;
        while (go) {
            if (oc == 0) {
                n = try_move(p, base, n, pack(sq, to, F_QUIET, 0));
                to = to + D8[d];
                oc = bd[to]
            } else {
                if (oc != OFF && (oc & 8) == foe && (oc & 7) != 6) {
                    n = try_move(p, base, n, pack(sq, to, F_QUIET, 0))
                };
                go = false
            }
        };
        d = d + 1
    };
    n
}

// gen_pawn(p, base, n, sq, foe) -- pushes, the double push, both captures and
// en passant, each with the four-way promotion at the far end.
//
// En passant is generated only when the square behind the capturing pawn
// really holds an enemy pawn.  A FEN may name an en-passant square that no
// pawn can reach (some tools record it unconditionally), and generating from
// the name alone would invent a move -- and worse, would remove whatever else
// sits there.
def gen_pawn(p: Pos, base: long, n: long, sq: long, foe: long) -> long {
    let bd = p.bd;
    let fwd = fwd_of(p.side);
    let startrow = if (p.side == 0) { 8 } else { 3 };
    let promorow = if (p.side == 0) { 2 } else { 9 };
    let one = sq + fwd;
    let promote = one / 10 == promorow;
    if (bd[one] == 0) {
        if (promote) {
            n = try_move(p, base, n, pack(sq, one, F_PROMO, 2));
            n = try_move(p, base, n, pack(sq, one, F_PROMO, 3));
            n = try_move(p, base, n, pack(sq, one, F_PROMO, 4));
            n = try_move(p, base, n, pack(sq, one, F_PROMO, 5))
        } else {
            n = try_move(p, base, n, pack(sq, one, F_QUIET, 0));
            if (sq / 10 == startrow && bd[one + fwd] == 0) {
                n = try_move(p, base, n, pack(sq, one + fwd, F_DPUSH, 0))
            }
        }
    };
    let c1 = sq + fwd + 1;
    let c2 = sq + fwd - 1;
    if (takeable(bd, c1, foe) && bd[c1] != 0) {
        if (promote) {
            n = try_move(p, base, n, pack(sq, c1, F_PROMO, 2));
            n = try_move(p, base, n, pack(sq, c1, F_PROMO, 3));
            n = try_move(p, base, n, pack(sq, c1, F_PROMO, 4));
            n = try_move(p, base, n, pack(sq, c1, F_PROMO, 5))
        } else {
            n = try_move(p, base, n, pack(sq, c1, F_QUIET, 0))
        }
    };
    if (takeable(bd, c2, foe) && bd[c2] != 0) {
        if (promote) {
            n = try_move(p, base, n, pack(sq, c2, F_PROMO, 2));
            n = try_move(p, base, n, pack(sq, c2, F_PROMO, 3));
            n = try_move(p, base, n, pack(sq, c2, F_PROMO, 4));
            n = try_move(p, base, n, pack(sq, c2, F_PROMO, 5))
        } else {
            n = try_move(p, base, n, pack(sq, c2, F_QUIET, 0))
        }
    };
    if (p.ep >= 0 && (c1 == p.ep || c2 == p.ep)) {
        let victim = p.ep - fwd;
        if (bd[victim] == 1 + foe) {
            n = try_move(p, base, n, pack(sq, p.ep, F_EPA, 0))
        }
    };
    n
}

// gen_castle(p, base, n, sq) -- king side and queen side, with all three
// restrictions: the right must be held, every square between must be empty,
// and the king may not be in check, pass through an attacked square, or land
// on one.  The attack scan is on the board BEFORE the move -- which is why
// castling cannot go through try_move like everything else, and why the king
// ends on a square the make-time test would otherwise never have looked at.
def gen_castle(p: Pos, base: long, n: long, sq: long) -> long {
    let bd = p.bd;
    let foe = p.side ^ 8;
    let home = if (p.side == 0) { 95 } else { 25 };
    let kright = if (p.side == 0) { CR_WK } else { CR_BK };
    let qright = if (p.side == 0) { CR_WQ } else { CR_BQ };
    if (sq != home || p.ksq[p.side / 8] != home) { return n };
    if ((p.castle & kright) != 0 && bd[home + 1] == 0 && bd[home + 2] == 0
        && bd[home + 3] == (4 + p.side)) {
        if (!attacked(bd, home, foe) && !attacked(bd, home + 1, foe)
            && !attacked(bd, home + 2, foe)) {
            n = try_move(p, base, n, pack(home, home + 2, F_CK, 0))
        }
    };
    if ((p.castle & qright) != 0 && bd[home - 1] == 0 && bd[home - 2] == 0
        && bd[home - 3] == 0 && bd[home - 4] == (4 + p.side)) {
        if (!attacked(bd, home, foe) && !attacked(bd, home - 1, foe)
            && !attacked(bd, home - 2, foe)) {
            n = try_move(p, base, n, pack(home, home - 2, F_CQ, 0))
        }
    };
    n
}

// gen_from(p, base, n, sq, pc) -- dispatch on the piece kind.
def gen_from(p: Pos, base: long, n: long, sq: long, pc: long) -> long {
    let kind = pc & 7;
    let foe = p.side ^ 8;
    if (kind == 1) { gen_pawn(p, base, n, sq, foe) }
    else if (kind == 2) { gen_leaper(p, base, n, sq, 2, foe, KN) }
    else if (kind == 6) {
        let k = gen_leaper(p, base, n, sq, 6, foe, KG);
        gen_castle(p, base, k, sq)
    } else { gen_slider(p, base, n, sq, kind, foe) }
}

// gen_all(p, base) -> how many LEGAL moves the position has.  They land in
// p.mv[base ..], in square order (a8 first) and, within a piece, in the
// fixed order of D8 and KN -- so the list is the same every run, which is what
// makes `--split` and `--moves` diffable.
//
// The scan walks the 64 real squares as eight rows of eight, and never the
// border.  Walking 21..98 instead looks equivalent and is not: the border
// squares hold OFF = 255, and 255 & 8 == 8, so every one of the ten border
// squares on a row reads as a black piece of kind 7 the moment it is black's
// turn -- six extra queens' worth of moves on every black position, and a
// perfectly correct-looking count on every white one.
def gen_all(p: Pos, base: long) -> long {
    let n = 0;
    let r = 0;
    while (r < 8) {
        let f = 0;
        let row = 21 + r * 10;
        while (f < 8) {
            let pc = p.bd[row + f];
            // `pc != 0` first, always.  `(pc & 8) == p.side` is TRUE for an
            // empty square whenever white is to move -- 0 & 8 == 0 -- so a
            // scan that tests the colour alone reads all 48 empty squares as
            // white bishops and answers 568 moves for the start position.
            if (pc != 0 && (pc & 8) == p.side) {
                n = gen_from(p, base, n, row + f, pc)
            };
            f = f + 1
        };
        r = r + 1
    };
    n
}

// ── perft ─────────────────────────────────────────────────────────────────

// perft(p, depth, base) -> the leaf nodes `depth` moves below the position.
//
// Two things keep it honest and fast: the leaf level is counted as
// `gen_all` and never played out (that alone is most of the speed), and the
// move list is read into a local BEFORE recursing, because the recursion
// generates into the NEXT level's region of the same buffer -- p.mv[base + i]
// read after the recursive call would be somebody else's move.
def perft(p: Pos, depth: long, base: long) -> long {
    let n = gen_all(p, base);
    if (depth <= 1) { return n };
    let total = 0;
    let i = 0;
    while (i < n) {
        let m = p.mv[base + i];
        let cap = make(p, m, base);
        total += perft(p, depth - 1, base + MVSTRIDE);
        unmake(p, m, base, cap);
        i = i + 1
    };
    total
}

// The deepest search the move buffer can hold, and the reason it is a
// diagnostic and not a trap: a deeper --depth would write past p.mv.
const MAXDEPTH: long = 9;

// ── the FEN reader ────────────────────────────────────────────────────────

// fen_piece(ch) -> the piece code for one FEN character, or -1.  Upper case is
// white, lower case black; there is no case-folding helper to lean on, so the
// twelve letters are named.
def fen_piece(ch: str) -> long {
    if (ch == "P") { 1 } else if (ch == "N") { 2 } else if (ch == "B") { 3 }
    else if (ch == "R") { 4 } else if (ch == "Q") { 5 } else if (ch == "K") { 6 }
    else if (ch == "p") { 9 } else if (ch == "n") { 10 } else if (ch == "b") { 11 }
    else if (ch == "r") { 12 } else if (ch == "q") { 13 } else if (ch == "k") { 14 }
    else { -1 }
}

// sq_name(sq) -> "e4", the other way round for --moves and --split.  The file
// is (sq - 21) % 10 and NOT sq % 10: the mailbox row is ten wide, so the
// columns are offset by the leading border square.  Getting that wrong names
// every square one file to the right -- a8 prints as b9 -- and the count is
// still right, so nothing complains.
def sq_name(sq: long) -> str {
    let rank = 10 - sq / 10;
    chr(97 + (sq - 21) % 10) + chr(48 + rank)
}

// name_sq(s) -> the square `s` names, or -1.  Two characters, a file a..h and
// a rank 1..8 -- each checked, so "z9" and "e0" are diagnosed by name.
def name_sq(s: str) -> long {
    if (s.length != 2) { return -1 };
    let f = ord(s[0:1]) - 97;
    let r = ord(s[1:2]) - 48;
    if (f < 0 || f > 7 || r < 1 || r > 8) { return -1 };
    21 + (8 - r) * 10 + f
}

// clear(p) -> p, emptied: the border back to OFF and the 64 squares to 0.
def clear(p: Pos) -> Pos {
    let sq = 0;
    let stop = false;
    while (stop == false) {
        if (sq > 119) {
            stop = true
        } else {
            p.bd[sq] = if (real_sq(sq)) { 0 } else { 255 };
            sq = sq + 1
        }
    };
    p.ksq[0] = 0;
    p.ksq[1] = 0;
    p.side = 0;
    p.castle = 0;
    p.ep = -1;
    p
}

// set_fen(p, fen) -> "" when the position is accepted, or the reason it is
// not.  Every rejection is a message naming what was wrong: the program exits
// non-zero on it, so a typo in a FEN can never turn into a count of a
// different game.
def set_fen(p: Pos, fen: str) -> str {
    clear(p);
    let f: [str] = [];
    let parts = fen.split(" ");
    let i = 0;
    while (i < len(parts)) {
        if (parts[i].length > 0) { f += parts[i] };
        i = i + 1
    };
    if (len(f) < 4) {
        return "FEN needs 4 fields (placement, side, castling, en passant), got " + tostring(len(f))
    };
    if (len(f) > 6) {
        return "FEN has " + tostring(len(f)) + " fields; the last two (halfmove, fullmove) are the only extras allowed"
    };
    // ── field 1: the placement ──
    let rows = f[0].split("/");
    if (len(rows) != 8) {
        return "the placement field must be 8 ranks separated by '/', got " + tostring(len(rows))
    };
    let np = [0; 2];
    let ntot = [0; 2];
    let pawn_on_home = false;
    let r = 0;
    while (r < 8) {
        let rank = 8 - r;
        let file = 0;
        let line = rows[r];
        let ci = 0;
        while (ci < line.length) {
            let ch = line[ci:ci + 1];
            let o = ord(ch) - 48;
            if (o >= 1 && o <= 8) {
                file += o
            } else {
                let pc = fen_piece(ch);
                if (pc < 0) {
                    return "rank " + tostring(rank) + ": '" + ch + "' is not a piece letter or a digit"
                };
                if (file > 7) {
                    return "rank " + tostring(rank) + ": too many squares before the '" + ch + "' at file " + tostring(file + 1)
                };
                let col = pc / 8;
                p.bd[21 + r * 10 + file] = pc;
                if ((pc & 7) == 6) {
                    if (np[col] != 0) {
                        return "the " + side_name(col) + " side has two kings"
                    };
                    np[col] = 1;
                    p.ksq[col] = 21 + r * 10 + file
                };
                if ((pc & 7) == 1 && (rank == 1 || rank == 8)) {
                    pawn_on_home = true
                };
                ntot[col] += 1;
                file += 1
            };
            ci += 1
        };
        if (file != 8) {
            return "rank " + tostring(rank) + " describes " + tostring(file) + " squares, not 8"
        };
        r = r + 1
    };
    if (np[0] == 0) { return "no white king (K)" };
    if (np[1] == 0) { return "no black king (k)" };
    if (pawn_on_home) { return "a pawn stands on the first or the eighth rank" };
    if (ntot[0] > 16 || ntot[1] > 16) {
        return "a side has more than 16 pieces"
    };
    if (count_pawns(p, 0) > 8 || count_pawns(p, 1) > 8) {
        return "a side has more than 8 pawns"
    };
    // ── field 2: the side to move ──
    if (f[1] == "w") { p.side = 0 }
    else if (f[1] == "b") { p.side = 8 }
    else { return "the side to move must be 'w' or 'b', got '" + f[1] + "'" };
    // ── field 3: castling availability ──
    if (f[2] != "-") {
        let seen = 0;
        let ci = 0;
        while (ci < f[2].length) {
            let ch = f[2][ci:ci + 1];
            let bit = 0;
            if (ch == "K") { bit = CR_WK } else if (ch == "Q") { bit = CR_WQ }
            else if (ch == "k") { bit = CR_BK } else if (ch == "q") { bit = CR_BQ }
            else { return "castling field: '" + ch + "' is not one of KQkq" };
            if ((seen & bit) != 0) { return "castling field: '" + ch + "' is given twice" };
            seen += bit;
            ci += 1
        };
        p.castle = seen
    };
    // ── field 4: the en-passant square ──
    if (f[3] != "-") {
        let sq = name_sq(f[3]);
        if (sq < 0) {
            return "en-passant field: '" + f[3] + "' is not a square like e3"
        };
        // White to move means black just made the double push, so the square
        // sits on the sixth rank; black to move, on the third.
        let want = if (p.side == 0) { 4 } else { 7 };
        if (sq / 10 != want) {
            return "en-passant field: '" + f[3] + "' is impossible with "
                + side_name(p.side / 8) + " to move"
        };
        if (p.bd[sq] != 0) { return "en-passant field: '" + f[3] + "' is not an empty square" };
        p.ep = sq
    };
    // ── fields 5 and 6, if present, must be numbers ──
    let ci = 4;
    while (ci < len(f)) {
        let d = true;
        let k = 0;
        while (k < f[ci].length) {
            let o = ord(f[ci][k:k + 1]) - 48;
            if (o < 0 || o > 9) { d = false };
            k = k + 1
        };
        if (!d) { return "field " + tostring(ci + 1) + " ('" + f[ci] + "') must be a number" };
        ci += 1
    };
    // ── the position itself must be reachable ──
    // The side that just moved may not be in check: that is not a FEN typo, it
    // is an impossible position, and a perft over one would quietly count a
    // game nobody can play.
    let foe = p.side ^ 8;
    if (attacked(p.bd, p.ksq[foe / 8], p.side)) {
        return "the " + side_name(foe / 8) + " king is in check with "
            + side_name(p.side / 8) + " to move"
    };
    ""
};

// side_name(0|1) -> "white" / "black".
def side_name(c: long) -> str {
    if (c == 0) { "white" } else { "black" }
}

// count_pawns(p, c) -- how many pawns the side has.  The FEN rules cap it at
// eight, and a ninth is a promotion that never happened, which no legal game
// can produce.
def count_pawns(p: Pos, c: long) -> long {
    let want = 1 + c * 8;
    let n = 0;
    let sq = 21;
    let stop = false;
    while (stop == false) {
        if (sq > 98) {
            stop = true
        } else {
            if (p.bd[sq] == want) { n += 1 };
            sq = sq + 1
        }
    };
    n
}

// ── printing a move ───────────────────────────────────────────────────────

// move_name(m) -> "e2e4", "e7e8q", "e1g1" for a castle.  Promotion gets its
// piece letter; a capture and a quiet move look the same, which is what a
// long-algebraic list looks like.
def move_name(m: long) -> str {
    let from = m & 255;
    let to = (m >> 8) & 255;
    let flag = (m >> 16) & 255;
    let promo = (m >> 24) & 15;
    let s = sq_name(from) + sq_name(to);
    if (flag == F_PROMO) {
        if (promo == 2) { s + "n" }
        else if (promo == 3) { s + "b" }
        else if (promo == 4) { s + "r" }
        else { s + "q" }
    } else { s }
}