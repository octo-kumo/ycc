// props.y -- the property checks.
//
// ===========================================================================
// WHY THIS FILE EXISTS AT ALL
// ===========================================================================
//
// A golden file proves DETERMINISM, not correctness.  It will record a defect
// and then reproduce that defect for ever, byte for byte, and pass every
// mechanical gate -- that is exactly how examples/cube shipped a wireframe that
// filled regions through a clean 8/8.  So nothing here reads EXPECTED, and
// nothing here compares against a reference.  Each check asks a question whose
// answer would be wrong if the logic were wrong, and prints the numbers it
// measured so the answer can be read rather than trusted.
//
//   (a) graph soundness   -- every room reachable from the start, every exit
//                            two-way, no room with two exits in one direction,
//                            over several seeds, by BFS over the graph AS BUILT
//   (b) session isolation -- two CONCURRENT clients in ONE room each hold the
//                            SAME item instance, each sees the room, and each
//                            sees the other player
//   (c) model agreement  -- the CLIENT's parsed map (room count, total exits,
//                            per-room exit count, per-room direction set) against
//                            world.y's arrays, field by field
//   (d) chat and state   -- chat arrives both ways through the pending region,
//                            and the two sessions' hit points are still separate
//
// (b) is the one a golden file cannot help with at all: "both players hold the
// torch" is a claim about a race, and a recorded race is a recorded coin toss.

import net;
import sockio;
import world;
import server;
import client;
import driver;

// Every verdict line bumps TOTAL, so `run` can print the tally without threading
// a counter through four functions.  A module-level array because a Y function
// cannot return two values, and declared up here because module-level `let`s do
// not hoist past their first use (a name declared later is an undefined-variable
// error).
let TOTAL: [long] = [0];

const SL2 = " room";
const ROOMS = "rooms ";
const UNR = "unreachable ";
const ONEW = "one-way ";
const DUP = "dup-dir ";
const BOTH = "both hold the same instance";
const SAMEROOM = "both are in one room";
const SAWOTHER = "each saw the other";

// The report is written into client 0's transcript region, because that is
// already a 64 KiB fixed byte buffer with append helpers -- no new sink, and the
// bytes go out with one write(1).
def kv(n: long, k: str, v: long) -> long {
    n = client.ss(n, "  ");
    n = client.ss(n, k);
    let i = len(k);
    while (i < 22) { n = client.ss(n, "."); i = i + 1 };
    n = client.ss(n, " ");
    n = client.sv(n, v);
    client.sn(n, 10)
};

// All of this file writes into the SUMMARY region with the summary family
// (sn / ss / sv).  An early version used the TRANSCRIPT family here
// (client.ts(0, k, s)), whose first argument is the client SLOT: the headings
// were written into client 0's transcript at whatever offset they had reached,
// and -- because the summary's offset ran past the transcript's -- they landed in
// a region the transcript had never filled, so the check's output began with a
// run of NUL bytes.  The two families are named for their buffers precisely so
// this is a one-glance mistake rather than a silent one.
def head(n: long, s: str) -> long {
    let k = client.ss(n, "  ");
    k = client.ss(k, s);
    k = client.sn(k, 10);
    let j = 0;
    while (j < 66) { k = client.ss(k, "-"); j = j + 1 };
    client.sn(k, 10)
};

// three numbers on one row, each under its own short heading
def row3(n: long, a: str, x: long, b: str, y: long, c: str, z: long) -> long {
    n = client.ss(n, "    ");
    n = client.ss(n, a); n = client.sv(n, x);
    n = client.ss(n, "  "); n = client.ss(n, b); n = client.sv(n, y);
    n = client.ss(n, "  "); n = client.ss(n, c); n = client.sv(n, z);
    client.sn(n, 10)
};

def two(n: long, a: str, x: long, b: str, y: long) -> long {
    n = client.ss(n, "    ");
    n = client.ss(n, a); n = client.sv(n, x);
    n = client.ss(n, "  "); n = client.ss(n, b); n = client.sv(n, y);
    client.sn(n, 10)
};

// A verdict line.  Returns n + 1 on a failure, so a check's fail count is its
// return value and the caller adds them up.  There is no `break` and no `continue`
// in Y (ORCHESTRATOR.md 2.9), which is why passing a count around is the
// readable way to do it.
def verdict(n: long, name: str, ok: bool, detail: str) -> long {
    n = client.ss(n, "    ");
    if (ok) {
        n = client.ss(n, "PASS  ");
    } else {
        n = client.ss(n, "FAIL  ");
    };
    n = client.ss(n, name);
    if (detail != "") {
        n = client.ss(n, "   [");
        n = client.ss(n, detail);
        n = client.ss(n, "]");
    };
    n = client.sn(n, 10);
    if (ok) { n } else { TOTAL[0] = TOTAL[0] + 1; n }
};

// ---------------------------------------------------------------------------
// (a) graph soundness
// ---------------------------------------------------------------------------

def check_graph(n: long, seed: long, ns: long) -> long {
    let bad = 0;
    n = head(n, "(a) the graph as built: reachable, two-way, unambiguous");
    n = client.ss(n, "    ");
    n = client.ss(n, "seed ");
    n = client.ss(n, "rooms");
    n = client.ss(n, " exits");
    n = client.ss(n, " unreachable");
    n = client.ss(n, " one-way");
    n = client.ss(n, " dup-dir");
    n = client.sn(n, 10);
    let s = 0;
    let tot = 0;
    let totu = 0;
    let totw = 0;
    let totd = 0;
    while (s < ns) {
        let sd = seed + s * 7;
        world.generate(sd);
        let u = world.unreachable();
        let w = world.one_way();
        let d = world.dup_dirs();
        n = seedrow(n, sd, world.rooms(), world.exits_total(), u, w, d);
        tot = tot + world.rooms();
        totu = totu + u;
        totw = totw + w;
        totd = totd + d;
        if (u + w + d != 0) { bad = bad + 1 };
        s = s + 1;
    };
    // the summary line carries the totals, which is the number to read
    n = client.ss(n, "    -- over ");
    n = client.sv(n, ns);
    n = client.ss(n, " seeds: ");
    n = client.sv(n, totu);
    n = client.ss(n, " unreachable, ");
    n = client.sv(n, totw);
    n = client.ss(n, " one-way, ");
    n = client.sv(n, totd);
    n = client.ss(n, " duplicate-direction (all must be 0)");
    n = client.sn(n, 10);
    n
};

// A per-seed line with all six numbers on it.  Separate from row3 because the
// numbers are six and row3 is three.
def seedrow(n: long, sd: long, rooms: long, exits: long, u: long, w: long, d: long) -> long {
    n = client.ss(n, "    seed ");
    n = client.svpad(n, sd, 7);
    n = client.ss(n, "  rooms ");
    n = client.svpad(n, rooms, 3);
    n = client.ss(n, "  exits ");
    n = client.svpad(n, exits, 4);
    n = client.ss(n, "  unreachable ");
    n = client.svpad(n, u, 3);
    n = client.ss(n, "  one-way ");
    n = client.svpad(n, w, 3);
    n = client.ss(n, "  dup-dir ");
    n = client.svpad(n, d, 3);
    client.sn(n, 10)
};

// ---------------------------------------------------------------------------
// (b) two concurrent clients, one room, one item instance
// ---------------------------------------------------------------------------

def check_isolation(n: long, port: long) -> long {
    let ca = 2;
    let cb = 3;
    let inst = server.first_floor_inst(0);
    if (inst < 0) { return verdict(n, "there is anything to take in the start room", false, "no") };
    driver.done_reset();
    // the buffers live in the spawned BLOCK, so they are allocated once per
    // thread -- which for a paired check is once per client, and never again
    spawn {
        let tx: [byte; 4096] = [0; 4096];
        let rx: [byte; 4096] = [0; 4096];
        let hold: [long; 2] = [0; 2];
        let tv: [long; 2] = [0; 2];
        let sa: [byte; 16] = [0; 16];
        driver.pair_one(ca, port, inst, "ada", tx, rx, hold, tv, sa)
    };
    spawn {
        let tx: [byte; 4096] = [0; 4096];
        let rx: [byte; 4096] = [0; 4096];
        let hold: [long; 2] = [0; 2];
        let tv: [long; 2] = [0; 2];
        let sa: [byte; 16] = [0; 16];
        driver.pair_one(cb, port, inst, "bo", tx, rx, hold, tv, sa)
    };
    driver.wait_done(2);
    // each client records how many items its pack ended with
    let ha = client.V_NCARRY[ca];
    let hb = client.V_NCARRY[cb];
    let both = ha > 0 && hb > 0;
    let ra = client.V_ROOM[ca];
    let rb = client.V_ROOM[cb];
    let same = ra >= 0 && ra == rb;
    let sa = client.V_OTHERS[ca];
    let sb = client.V_OTHERS[cb];
    let saw = sa > 0 && sb > 0;
    n = head(n, "(b) two concurrent clients, one room, one item instance");
    n = client.ss(n, "    both take instance ");
    n = client.sv(n, inst);
    n = client.ss(n, " (");
    n = client.ss(n, world.item_name(world.i_id(inst)));
    n = client.ss(n, ") by id, after a sync barrier");
    n = client.sn(n, 10);
    n = two(n, "ada pack", ha, "bo pack", hb);
    n = two(n, "ada room", ra, "bo room", rb);
    n = two(n, "ada saw", sa, "bo saw", sb);
    n = client.ss(n, "    a SHARED world would let exactly one of them have it,");
    n = client.sn(n, 10);
    n = client.ss(n, "    and which one would depend on thread timing");
    n = client.sn(n, 10);
    n = verdict(n, BOTH, both, "per-session worlds");
    n = verdict(n, SAMEROOM, same, "both logged into room 0");
    n = verdict(n, SAWOTHER, saw, "+ROTH lines");
    n
};

// ---------------------------------------------------------------------------
// (c) the client's parsed map against the server's model
// ---------------------------------------------------------------------------

def check_model(n: long, c: long) -> long {
    let rooms = world.rooms();
    let exits = world.exits_total();
    let nrooms = client.V_MAPROOMS[c];
    let nexits = client.V_MAPEXITS[c];
    let nseen = client.V_MAPSEEN[c];
    let nbad = client.V_MAPBAD[c];
    // per room: exit count and the direction set
    let mismatch = 0;
    let first = 0 - 1;
    let r = 0;
    while (r < rooms) {
        let wn = world.ex_n(r);
        let cn = client.M_NEX[c * client.MAPR + r];
        let wm = 0;
        let d = 0;
        while (d < 4) {
            if (world.ex_to(r, d) >= 0) { wm = wm | (1 << d) };
            d = d + 1;
        };
        let cm = client.M_MASK[c * client.MAPR + r];
        if (wn != cn || wm != cm) {
            mismatch = mismatch + 1;
            if (first < 0) { first = r };
        };
        r = r + 1;
    };
    n = head(n, "(c) the client's parsed map against the server's model");
    n = two(n, "rooms: client", nrooms, "server", rooms);
    n = two(n, "exits: client", nexits, "server", exits);
    n = two(n, "+MR lines parsed", nseen, "out-of-range", nbad);
    n = two(n, "per-room mismatches", mismatch, "rooms compared", rooms);
    if (first >= 0) {
        n = client.ss(n, "    first mismatch: room ");
        n = client.sv(n, first);
        n = client.ss(n, " server says ");
        n = client.sv(n, world.ex_n(first));
        n = client.ss(n, " exits, client says ");
        n = client.sv(n, client.M_NEX[c * client.MAPR + first]);
        n = client.sn(n, 10);
    };
    n = verdict(n, "room count agrees", nrooms == rooms, "");
    n = verdict(n, "total exits agree", nexits == exits, "");
    n = verdict(n, "every room was sent", nseen == rooms, "");
    n = verdict(n, "no out-of-range room id", nbad == 0, "");
    n = verdict(n, "exits and directions agree per room", mismatch == 0, "field by field");
    n
};

// ---------------------------------------------------------------------------
// (d) chat both ways, and state still separate
// ---------------------------------------------------------------------------

def check_chat(n: long, port: long) -> long {
    let ca = 4;
    let cb = 5;
    let rc = driver.run_chat_pair(port, ca, cb);
    let ma = client.V_NMSG[ca];
    let mb = client.V_NMSG[cb];
    n = head(n, "(d) chat both ways, through the pending region");
    n = two(n, "ada received", ma, "bo received", mb);
    n = two(n, "ada hp", client.V_HP[ca], "bo hp", client.V_HP[cb]);
    n = two(n, "ada exits", client.V_NEX[ca], "bo exits", client.V_NEX[cb]);
    n = verdict(n, "ada heard bo", ma > 0, "barrier-ordered");
    n = verdict(n, "bo heard ada", mb > 0, "barrier-ordered");
    n = verdict(n, "both connections ended cleanly", rc == 0, "");
    n
};

// ---------------------------------------------------------------------------
// (e) the step table's own determinism property
// ---------------------------------------------------------------------------
//
// A static check, no socket.  Chat is promoted for delivery by the barrier that
// opens (server.y, "CHAT: STAGED, THEN PROMOTED"), so a message is delivered at
// the FIRST barrier after the `say` that produced it -- and the table has to
// guarantee that such a barrier exists before the next `say`, or a message would
// wait a whole cycle and the two transcripts would disagree about when it
// arrived.  So: between any two `say` steps there must be a barrier, cyclically.
//
// It is a weaker condition than the first version of this check, and that is the
// point: with the promotion done by the barrier, the table no longer has to be
// arranged around the chat drain at all.  The barriers are still worth having --
// they are what orders the room view and the end of the script -- so the check
// stays, as a statement of what the table is for.

def check_table(n: long) -> long {
    let steps = driver.step_count();
    let says = 0;
    let syncs = 0;
    let k = 0;
    while (k < steps) {
        if (driver.step_is_say(k)) { says = says + 1 };
        if (driver.step_is_sync(k)) { syncs = syncs + 1 };
        k = k + 1;
    };
    // between any two `say` steps, cyclically, there is at least one barrier
    let orphan = 0;
    let first = 0 - 1;
    let j = 0;
    while (j < steps) {
        if (driver.step_is_say(j)) {
            let d = 1;
            let seen = 0;
            while (d < steps && !driver.step_is_sync((j + d) % steps)) {
                if (driver.step_is_say((j + d) % steps)) { seen = 1 };
                d = d + 1;
            };
            if (seen == 1) {
                orphan = orphan + 1;
                if (first < 0) { first = j };
            };
        };
        j = j + 1;
    };
    n = head(n, "(e) the client's step table: every message is delivered once");
    n = two(n, "steps in the table", steps, "barriers", syncs);
    n = two(n, "say steps", says, "says with no barrier between", orphan);
    n = verdict(n, "the table has at least one barrier", syncs > 0, "or nothing orders the chat");
    n = verdict(n, "the table has at least one say", says > 0, "or (d) checks nothing");
    n = verdict(n, "a barrier falls between every two says", orphan == 0, "next one promotes");
    if (orphan > 0) {
        n = client.ss(n, "    first say with no barrier before the next: step ");
        n = client.sv(n, first);
        n = client.sn(n, 10);
    };
    n
};

// ---------------------------------------------------------------------------
// the whole run
// ---------------------------------------------------------------------------
//
// Each check returns its FAILURE COUNT and appends its report to client 0's
// transcript region, so the caller owns the length and the tally.  (Writing the
// length back through a shared pointer would need a `long` out-parameter, and
// `n + 1 per failure` cannot be recovered from a length the function was also
// handed -- so the count comes back as the value and the text goes out through
// the buffer.)

def run(seed: long, nw: long) -> long {
    let n = 0;
    n = client.ss(n, "================================================================\n");
    n = client.ss(n, "  mud --check: property checks, no reference file involved\n");
    n = client.ss(n, "================================================================\n");
    n = client.sn(n, 10);

    // (a) needs no socket at all, and runs FIRST so a broken world is reported
    // before anything is opened.  Eight seeds: the graph properties are the kind
    // of thing that holds for one seed and fails for another.
    n = check_graph(n, seed, 8);
    n = client.sn(n, 10);

    // (e) is static too, and belongs next to (a): it is the one thing that has
    // to be true for the OTHER checks to mean anything reproducible.
    n = check_table(n);
    n = client.sn(n, 10);

    // EACH CHECK GETS ITS OWN SERVER.  The acceptor's connection count is a
    // budget, not a rate: one server sized for all four checks (4 connections)
    // ran out during (d), and the client that missed out got no reply at all --
    // reported as "ada heard bo: FAIL" when what had happened was that ada had
    // never been accepted.  Four servers on four ephemeral ports also means one
    // check cannot see another's sessions.
    world.generate(seed);
    let p1 = sockio.port_of(driver.serve(nw, 2, 2, seed));
    n = check_isolation(n, p1);
    driver.stop(nw);
    n = client.sn(n, 10);

    // (c) needs a client that has been asked for the map.  `map` is the last
    // command run_client sends, after its frames, so any frame count gets there.
    world.generate(seed);
    let p2 = sockio.port_of(driver.serve(nw, 1, 1, seed));
    driver.done_reset();
    spawn {
        let tx: [byte; 4096] = [0; 4096];
        let rx: [byte; 4096] = [0; 4096];
        let hold: [long; 2] = [0; 2];
        let tv: [long; 2] = [0; 2];
        let sa: [byte; 16] = [0; 16];
        driver.run_client(0, p2, 6, 1, tx, rx, hold, tv, sa)
    };
    driver.wait_done(1);
    n = check_model(n, 0);
    driver.stop(nw);
    n = client.sn(n, 10);

    world.generate(seed);
    let p3 = sockio.port_of(driver.serve(nw, 2, 2, seed));
    n = check_chat(n, p3);
    driver.stop(nw);

    n = client.ss(n, "================================================================\n");
    if (TOTAL[0] == 0) {
        n = client.ss(n, "  ALL PROPERTY CHECKS PASS\n");
    } else {
        n = client.ss(n, "  ");
        n = client.sv(n, TOTAL[0]);
        n = client.ss(n, " FAILURES\n");
    };
    client.SUMLEN[0] = n;
    client.emit_summary();
    0
};

export { TOTAL, run, check_graph, check_isolation, check_model, check_chat, check_table,
         verdict, seedrow, kv, head, two, row3 };
