// yserve.y -- the language server's entry point.
//
// This file is deliberately the smallest of the set. Everything it does is:
//
//   1. read one Content-Length frame from stdin,
//   2. fork a child that handles it and writes its own reply to stdout,
//   3. wait for the child, then go back to 1.
//
// Everything else -- the protocol, the diagnostics, the positions, the formatter
// -- lives in a module that can be tested by handing it strings. The loop is the
// only part that needs a real process, and it is small enough to read in one go.
//
// WHY FORK PER MESSAGE (LSP.md §4.2). The compiler this server drives is built
// to run once and exit. `lexer.tokenize` calls exit(1) on an unterminated
// string or block comment, `native.native_resolve_x` calls exit(1) on an
// import it cannot open, `syscall(60, ...)` is how the runtime ends a process,
// and a run never frees its heap. Any of those in the server's own address space
// is a server that dies on the first typo -- and a user typing a string literal
// is the common case, not the rare one. A child that dies takes only its own
// reply, and the parent's only mutable state is the read buffer and the frame
// cursor, neither of which a request handler touches.
//
// The parent therefore never parses JSON, never runs the checker, and never
// touches a compiler global. If a handler corrupts anything, the corruption is
// thrown away with the child.
//
// RESPONSES COME OUT IN ORDER. One child at a time, each waited for before the
// next frame is read. LSP permits out-of-order replies, but a checker walk costs
// single-digit milliseconds on these files, so overlapping buys nothing -- and
// serialising means two half-written frames can never interleave on one stdout.

import json;

// native.y reads AND WRITES `res_target` (the one target global) and imports
// nothing for it: it is the program's job, and `ycc.y` does it -- first, so
// the binding is spliced before any reader. The server is a second program
// that path-imports native.y, so it must do the same, in the same order.
import wintgt from "../../y/target.y";
import native from "../../y/native.y";
import fmt from "./fmt.y";
import rpc from "./rpc.y";
import serve from "./serve.y";
import dispatch from "./dispatch.y";

// The two file descriptors, spelled out because there is no stdio module: the
// protocol is defined in terms of them and nothing else in the program opens
// them. fs comes in by name through serve.y -> diag.y -> native.y; see the note
// there about why it must not be imported here as well.
const FD_IN = 0;
const FD_OUT = 1;

// The fd the replies go to. The client reads ONLY this one, and the protocol
// says every byte on it is a framed message -- so before forking, the parent
// duplicates stdout here and the child points its OWN stdout at stderr. Without
// that, one line of compiler output lands in the middle of the stream:
//
//     error: cannot open import './nope.y' (resolved to 'nope.y')
//
// which native.native_resolve_x prints to stdout on its way to exit(1). A real
// client would read that as a malformed frame, lose its place, and drop the
// connection. Redirecting the child's stdout to stderr turns a protocol
// violation into a line in the client's log, which is where it belongs.
//
// dup(2) is syscall 32 and dup2(2) is 33 on x86-64. 200 is chosen because the
// runtime hands out low fds for files and nothing else here opens any.
const FD_REPLY = 200;

// Where the child's own stdout goes: stderr, where the client's log collects it.
const FD_LOG = 2;

// Options, from argv: the workspace root, the std pack, and the warning level.
// These match `ycc`'s own flags where they overlap, so a user configures the
// editor and the command line the same way.
type YsOpts = { root: str, pack_out: str, use_pack: bool, wlevel: long, fmt_file: str };

def parse_opts(av: [str]) -> YsOpts {
    let root = "";
    let pack_out = "";
    let use_pack = true;
    let wlevel = 0;
    let fmt_file = "";
    let i = 1;
    while (i < len(av)) {
        let a = av[i];
        if (a == "--root" && i + 1 < len(av)) { root = av[i + 1]; i = i + 2; }
        else if (a == "--std-pack" && i + 1 < len(av)) { pack_out = av[i + 1]; i = i + 2; }
        else if (a == "--std-src") { use_pack = false; i = i + 1; }
        else if (a == "--fmt" && i + 1 < len(av)) { fmt_file = av[i + 1]; i = i + 2; }
        else if (a == "-W" || a == "--wlevel") { wlevel = 1; i = i + 1; }
        else if (a == "--help" || a == "-h") { yserve_usage(); syscall(60, 0); }
        else { i = i + 1; }
    }
    // No root given: use the directory the server was started in, which is what
    // a single-file editor wants and what a workspace client that omits
    // rootUri effectively asks for.
    if (root == "") { root = fs.cwd(); }
    let o: YsOpts = { root: root, pack_out: pack_out, use_pack: use_pack, wlevel: wlevel, fmt_file: fmt_file };
    o
}

// Named for yserve, not `usage`: a path import flattens the compiler's
// modules into this namespace and std/args.y already defines `usage`.
def yserve_usage() -> long {
    fs.write_text(FD_LOG, "yserve -- the Y language server (JSON-RPC 2.0 over stdio)\n\n"
        + "  --root DIR      the workspace root imports resolve against (default: cwd)\n"
        + "  --std-pack FILE compile the std units and write them to FILE, then exit\n"
        + "  --std-src       ignore an attached std pack and compile the units from source\n"
        + "  -W              the optional level-1 warnings, as `ycc -W`\n"
        + "  --fmt FILE      format FILE and write it to stdout, then exit\n");
    0
}

// ── the std pack ────────────────────────────────────────────────────────
//
// The same framing `ycc` uses, and for the same reason: a server that attached
// no pack compiles the std units from SOURCE on every request, because that is
// what `std_units(names, "")` does. With the pack it reads precompiled units.
//
// The frame is [pack][the pack's length, 8 digits][YCCPACK1], appended to the
// binary by `make yserve`. Reading it means seeking to the end of our own
// executable, which is /proc/self/exe -- there is no argv[0] trick that works
// when the client started us by absolute path from somewhere else entirely.

const PACK_MAGIC = "YCCPACK1";

def ys_pack_magic() -> str { PACK_MAGIC }

// The pack attached to this binary, or "" when there is none.
def ys_self_pack() -> str {
    let out = "";
    let fd = syscall(257, -100, "/proc/self/exe", 0, 0);
    if (fd < 0) { return out; }
    let size = syscall(8, fd, 0, 2);
    if (size >= 16) {
        let buf: [byte; 65536] = [0; 65536];
        syscall(8, fd, size - 16, 0);
        if (syscall(0, fd, &buf[0], 16) == 16) {
            let tail = from_bytes(buf[0:16]);
            // A binary with no pack has whatever the linker left in its last
            // 16 bytes, so the size field is not a number. The old tolong read
            // that as 0 and the check below rejected it; with `!` it traps.
            let nopt = tolong(tail[:8]);
            if (nopt != none && tail[8:] == ys_pack_magic() && nopt ! > 0 && nopt ! <= size - 16) {
                let n = nopt !;
                syscall(8, fd, size - 16 - n, 0);
                let pieces: [str] = [];
                let left = n;
                while (left > 0) {
                    let want = left;
                    if (want > 65536) { want = 65536; }
                    let got = syscall(0, fd, &buf[0], want);
                    if (got <= 0) {
                        left = -1;
                    } else {
                        // a slice copies byte by byte, so only a full chunk pays it
                        if (got == 65536) { pieces += from_bytes(buf); } else { pieces += from_bytes(buf[0:got]); };
                        left = left - got;
                    }
                };
                if (left == 0) { out = join(pieces, ""); }
            }
        }
    }
    syscall(3, fd);
    out
}

// --std-pack FILE: every std unit, compiled from source, framed for attaching.
def ys_write_pack(path: str) -> long {
    let pack = std_pack(std_units(std_unit_names(), ""));
    let nd = tostring(len(pack));
    while (len(nd) < 8) { nd = "0" + nd; };
    if (len(nd) > 8) {
        fs.write_text(FD_LOG, "error: the std pack is too large (" + nd + " bytes)\n");
        return 1;
    }
    if (!fs.write_file(path, pack + nd + ys_pack_magic())) {
        fs.write_text(FD_LOG, "error: writing '" + path + "' failed\n");
        return 1;
    }
    0
}

// Handle one message, returning the BODY of every frame it produces -- one
// entry per frame, NOT one concatenated string.
//
// That distinction is the framing. A frame is `Content-Length: N` then exactly
// N bytes of one JSON value, so two messages in one write need two headers. The
// first version of this returned a concatenation and the client saw two JSON
// objects where it expected one: a parse error, and then a stream it could no
// longer find its place in. It only showed up once one message could produce
// more than one frame (a buffer whose findings span the file and an import).
def handle_one(st: State, raw: str) -> [str] {
    let parsed = json.parse(raw);
    let out: [str] = [];
    if (!is_some(parsed)) {
        // A frame whose body is not JSON gets ParseError and nothing else: there
        // is no id to answer, and a client that sent this has lost sync already.
        // (The parent stays alive; see the fork note at the top.)
        out += serve.error_msg(json.nul(), serve.E_PARSE, "the message body is not JSON");
        return out;
    }
    let msg = json.jobj(parsed !);
    let id = dispatch.msg_id(msg);
    let method = dispatch.msg_method(msg);
    if (method == "") {
        // A response to a request this server never made, or garbage with no
        // method. If it carries an id, answer it, because an unanswered id is
        // what makes a client hang.
        if is_some(id) { out += serve.error_msg(id !, serve.E_INVALID_REQUEST, "no method in the message"); }
        return out;
    }
    let p = dispatch.msg_params(msg);
    if (!is_some(id)) {
        // A notification: no reply, whatever happens inside.
        out += dispatch.doc_notification(st, method, p);
    } else {
        let life = dispatch.lifecycle(st, id !, method);
        if is_some(life) {
            out += life !;
        } else if (!st.initialized) {
            // The protocol requires this refusal: the client has not sent
            // rootUri, so imports cannot be resolved, and any answer would use
            // the wrong base directory. LSP makes it a specific code, and a
            // client retries after it.
            out += dispatch.not_initialized(id !);
        } else {
            out += dispatch.doc_request(st, id !, method, p);
        }
    }
    out
}

// `HH:MM:SS.mmm`, wall clock. Without it the timing lines are unusable for the only
// question they are asked: the numbers are small (a whole-file token request is tens
// of milliseconds) and the editor is still frozen, so the time has to be BETWEEN the
// lines, not in them. A wall-clock prefix makes an idle gap impossible to miss.
//
// `time_us`, not `clock_us`: this is for a person reading a log, and the wall clock
// is what they compare against the clock in the corner of the screen. The deltas
// that matter are milliseconds, so monotonic-vs-wall is not worth thinking about here.
def stamp() -> str {
    let us = time_us();
    let secs = us / 1000000;
    let ms = (us % 1000000) / 1000;
    let tod = secs % 86400;
    let h = tod / 3600;
    let mi = (tod % 3600) / 60;
    let se = tod % 60;
    let hh = tostring(h);
    let mm = tostring(mi);
    let ss = tostring(se);
    let m3 = tostring(ms);
    if (len(hh) < 2) { hh = "0" + hh; };
    if (len(mm) < 2) { mm = "0" + mm; };
    if (len(ss) < 2) { ss = "0" + ss; };
    while (len(m3) < 3) { m3 = "0" + m3; };
    hh + ":" + mm + ":" + ss + "." + m3
}

// A line in the client's output channel, timestamped and prefixed `yserve:`, so a
// reader can tell a server line from a client one at a glance. FD_LOG is stderr,
// which is where the extension's outputChannel collects everything.
//
// Lifecycle only -- start, ready, stop -- plus the totals. These three moments are
// what a person needs and nothing else gives them: whether the server is up at all,
// how long it took to be usable, and where the time went. The per-request lines are
// separate and behind y.lsp.timing.
def log_line(msg: str) {
    fs.write_text(FD_LOG, stamp() + "  yserve: " + msg + "\n");
}

// Elapsed since this process started reading its clock, in ms. Used for uptime and
// for the startup breakdown, so "ready after 12ms" is a measurement and not a claim.
let born_ms = -1;

def since_born_ms() -> long {
    if (born_ms < 0) { -1 } else {(clock_us() - born_ms) / 1000 }
}

def log_start(argv: [str], pack_bytes: long) {
    born_ms = clock_us();
    // getpid is syscall 39 on x86-64 Linux. Nothing in std exposes it and a
    // lifecycle line is not worth adding a std builtin for.
    log_line("start  pid " + tostring(syscall(39, 0)) + "  argv [" + join(argv, " ") + "]");
    if (pack_bytes > 0) {
        log_line("std pack attached: " + tostring(pack_bytes) + " bytes");
    } else {
        // Worth saying out loud, because it is the difference between a fast server
        // and one that recompiles every std unit on every request.
        log_line("no std pack: every std unit is compiled from SOURCE on every request");
    };
}

def log_ready(docs_open: long) {
    log_line("ready  " + tostring(since_born_ms()) + "ms after start  "
        + tostring(docs_open) + " documents open  "
        + tostring(heap_used() / 1024) + "KB heap");
}

def log_stop(reason: str, handled: long, forked: long, errors: long) {
    log_line("stop   " + reason + "  after " + tostring(since_born_ms()) + "ms  "
        + tostring(handled) + " messages handled  " + tostring(forked)
        + " handlers forked  " + tostring(errors) + " errors");
}

// The method name out of the raw frame, for the timing line. A substring search
// rather than a second json.parse: the message has already been parsed twice (once
// in the parent by apply_state, once in the child by handle_one), and a log line is
// not worth a third walk of a buffer that is a whole document on didChange.
def method_of_raw(raw: str) -> str {
    let k = index_of(raw, "\"method\":\"");
    if (k < 0) { k = index_of(raw, "\"method\": \""); };
    if (k < 0) {
        "?"
    } else {
        let rest = raw[k + 10:];
        let e = index_of(rest, "\"");
        if (e <= 0) { "?" } else { rest[0:e] }
    }
}

// Per-request timing, to the client's own log.
//
// stderr is where a language client already collects server output -- extension.ts
// passes `outputChannel: output` for exactly this -- so a line written to FD_OUT
// after the child's dup2 lands in the "Y" output channel under View: Toggle Output.
// No new protocol and no new setting: the channel the extension already creates is
// where a person looks for what the server is doing.
//
// The child's half: what this one request cost. The queueing half is the PARENT's
// blocked time and is logged from there, because that is where it happens -- see
// log_blocked.
//
// `wait` used to be printed here, stamped at the parent's read of the frame. It was
// always 0-3 ms and it was measuring nothing: the parent does almost nothing
// between reading a frame and forking, so the message had not been sitting
// anywhere yet. The delay a client actually sees is spent AFTER that, in the
// parent's wait_pid on the handlers ahead of it.
// Only what is worth reading.
//
// Three cuts, all of them about volume, and volume is the cost: a line here is an
// appendLine on the extension host, which is the thread a slow editor is made of.
// A real trace had roughly HALF its lines be `$/setTrace` -- the client re-asserting
// its trace setting, six times in one millisecond -- each one a fork and two lines
// recording that nothing happened. So:
//
//   * `$/...` is never logged. That is protocol chatter between the client and its
//     own library: no information, and the client sends it whether or not we care.
//   * A request that cost less than the threshold is not logged individually. What a
//     person reads this for is the slow one; a line per keystroke is a wall of text
//     with the answer somewhere in it.
//   * The parent's blocked time is cut the same way, and blocked is ~work plus a fork,
//     so the two thresholds agree by construction.
//
// Every slow request still appears, and `idle` still reports the gaps, which is the
// part that actually located the problem. Only the noise goes.
const TIMING_MIN_US = 30000;

def log_work(method: str, work_us: long) {
    if (method[:2] == "$/" || work_us < TIMING_MIN_US) { return; };
    fs.write_text(FD_OUT, stamp() + "  yserve  " + method + "  work "
        + tostring(work_us / 1000) + "ms\n");
}

// The parent's half, and the number that explains a freeze. This loop runs one
// handler at a time, so every message that arrives while a handler is running waits
// for it -- and that wait is serialised, summed over the whole backlog. On
// src/y/asm.y a handler is ~30 ms, so a thousand queued messages is half a minute
// of one core, and the editor sees no highlighting for the whole of it.
//
// FD_LOG, not FD_OUT: the parent's fd 1 is the framed protocol stream, and writing
// a log line into it would corrupt the stream. Only the child dup2s its stdout onto
// the log, which is why log_work can use FD_OUT.
def log_blocked(us: long) {
    if (us < TIMING_MIN_US) { return; };
    fs.write_text(FD_LOG, stamp() + "  yserve  [parent] blocked " + tostring(us / 1000)
        + "ms waiting for a handler\n");
}

// How long the parent sat in read_frame with nothing to do.
//
// This is the number that decides WHERE a freeze is. `blocked` only counts time the
// parent spends waiting for a handler it already has. If the editor is frozen and
// `blocked` is small, the parent is not the busy one -- it is sitting in this call,
// and the time is going to work that never reached the server at all: the client, the
// extension host, or the disk. Without this line that is a guess; with it, the log
// says which side of the socket is behind.
def log_idle(us: long) {
    fs.write_text(FD_LOG, stamp() + "  yserve  [parent] idle " + tostring(us / 1000)
        + "ms waiting for a message\n");
}

// Claim the reply fd, once, before the first fork so every child inherits it.
// dup returns the new fd, or a negative errno.
def claim_reply_fd() -> long {
    let fd = syscall(32, FD_OUT, FD_REPLY, 0);
    if (fd > 0) { fd } else { FD_OUT }
}

// The loop. Reads frames until stdin ends or `exit` arrives.
//
// ONE handler at a time: it waits for each child before reading the next frame, so
// a burst is a queue and its wall time is the SUM of its handlers rather than their
// maximum. Measured on src/y/asm.y, 30 ms of CPU per hover, all in the child, so
// the queue is what the editor feels. The timing
// lines above make that visible rather than inferred: `wait` is the queue, `work` is
// the cost.
//
// Making the handlers overlap is the obvious next step -- reap with wait4(WNOHANG)
// instead of blocking, and bound how many may run at once. It is NOT done here
// because the first attempt at it left finished children unreaped, and a server that
// drops replies is worse than a server that is slow. The measurements it needs are
// now in the output channel.
def serve_loop(st: State, fd_in: long) -> long {
    let reply = claim_reply_fd();
    let r = rpc.in_new();
    let go = true;
    let code = 0;
    let idle_since = clock_us();
    let handled = 0;
    let forked = 0;
    let errors = 0;
    log_ready(len(st.open));
    while (go) {
        let got = rpc.read_frame(r, fd_in);
        let idle_us = clock_us() - idle_since;
        idle_since = clock_us();
        // A gap under 200 ms is ordinary -- a person thinking -- and logging every
        // one would bury the lines that matter. A gap this size IS the freeze.
        if (idle_us > 200000 && st.timing) { log_idle(idle_us); };
        if (!is_some(got)) {
            // Clean end of input: the client closed the connection. Exiting 0
            // here is right -- this is how a client says "I am done", and the
            // LSP spec says the server should not treat it as an error.
            log_stop("input closed by the client", handled, forked, errors);
            go = false;
        } else {
            handled = handled + 1;
            let raw = got !;

            // The parent's own work: record what this message changed. Done
            // BEFORE the fork so the child inherits an up-to-date view, and done
            // in the parent because a child's writes die with it (dispatch.y
            // apply_state). Nothing here can exit -- see the note there.
            let leaving = dispatch.apply_state(st, raw);
            if (leaving) {
                // `exit` is a notification: no reply, and the client is done.
                log_stop("the client sent exit", handled, forked, errors);
                go = false;
            } else {
                let child = fork {
                    // Point this process's stdout at stderr FIRST, so anything the
                    // compiler prints -- an import it cannot open, a trap message --
                    // lands in the client's log instead of in the framed stream.
                    syscall(33, FD_LOG, FD_OUT, 0);
                    let timed = st.timing;
                    let t0 = clock_us();
                    let bodies = handle_one(st, raw);
                    let k = 0;
                    while (k < len(bodies)) {
                        rpc.write_frame(reply, bodies[k]);
                        k = k + 1;
                    };
                    if (timed) { log_work(method_of_raw(raw), clock_us() - t0); };
                    // exit_group(0): the child must not return into the runtime's
                    // normal exit path, which would flush the parent's buffers and
                    // run atexit handlers twice.
                    syscall(60, 0);
                    0
                };
                forked = forked + 1;
                if (child > 0) {
                    // The pid, or -errno. A negative result is a fork failure, not a
                    // child: there is nothing to wait for, and the loop must not
                    // spin forever on a resource limit.
                    let w0 = clock_us();
                    let status = wait_pid(child);
                    if (st.timing) { log_blocked(clock_us() - w0); };
                    if (status < 0) {
                        // The child died on a signal, or wait4 itself failed. A
                        // request that crashes the child must not take the server
                        // with it, and the client needs SOME answer or it waits
                        // forever -- so the failure is reported in the protocol's own
                        // terms.
                        rpc.write_frame(reply, serve.error_msg(json.nul(), serve.E_INTERNAL, "the request handler failed"));
                        go = false;
                        code = 1;
                    }
                } else {
                    // fork(2) failed outright: out of processes or memory. Retrying
                    // would spin; reporting and stopping is the honest answer.
                    errors = errors + 1;
                    log_stop("fork failed", handled, forked, errors);
                    rpc.write_frame(reply, serve.error_msg(json.nul(), serve.E_INTERNAL, "cannot fork a request handler"));
                    go = false;
                    code = 1;
                }
            }
        }
    }
    code
}

// `yserve --fmt FILE`: format FILE and write it to stdout (LSP.md R3.8), so
// the formatter is reachable from the shell -- and from make -- without a
// client. A buffer scan.y cannot lex is refused (R3.4): nothing is written and
// the exit code says so.
def ys_fmt_file(path: str) -> long {
    let got = fs.read_file(path);
    if (got == none) {
        fs.write_text(FD_LOG, "error: cannot read '" + path + "'\n");
        return 1;
    };
    let out = fmt.fmt(got !);
    if (out == none) {
        fs.write_text(FD_LOG, "error: '" + path + "' does not lex; left alone\n");
        return 1;
    };
    fs.write_text(FD_OUT, out !);
    0
}

def serve_main() -> long {
    let o = parse_opts(argv());
    if (o.fmt_file != "") {
        return ys_fmt_file(o.fmt_file);
    }
    if (o.pack_out != "") {
        // A build step, not a request: write the pack and stop. Nothing is
        // served, so no frame is written and stdout stays empty.
        let rc = ys_write_pack(o.pack_out);
        return rc;
    }
    let pack = "";
    if (o.use_pack) { pack = ys_self_pack(); }
    log_start(argv(), len(pack));
    let st = serve.server_state(o.root, pack, o.wlevel);
    serve_loop(st, FD_IN)
}

// The entry point. A `def main` is just a function: Y has no implicit call, so
// this last line is what starts the server.
let code = serve_main();
