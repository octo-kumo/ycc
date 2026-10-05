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

import native from "../../y/native.y";
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
type YsOpts = { root: str, pack_out: str, use_pack: bool, wlevel: long };

def parse_opts(av: [str]) -> YsOpts {
    let root = "";
    let pack_out = "";
    let use_pack = true;
    let wlevel = 0;
    let i = 1;
    while (i < len(av)) {
        let a = av[i];
        if (a == "--root" && i + 1 < len(av)) { root = av[i + 1]; i = i + 2; }
        else if (a == "--std-pack" && i + 1 < len(av)) { pack_out = av[i + 1]; i = i + 2; }
        else if (a == "--std-src") { use_pack = false; i = i + 1; }
        else if (a == "-W" || a == "--wlevel") { wlevel = 1; i = i + 1; }
        else if (a == "--help" || a == "-h") { yserve_usage(); syscall(60, 0); }
        else { i = i + 1; }
    }
    // No root given: use the directory the server was started in, which is what
    // a single-file editor wants and what a workspace client that omits
    // rootUri effectively asks for.
    if (root == "") { root = fs.cwd(); }
    let o: YsOpts = { root: root, pack_out: pack_out, use_pack: use_pack, wlevel: wlevel };
    o
}

// Named for yserve, not `usage`: a path import flattens the compiler's
// modules into this namespace and std/args.y already defines `usage`.
def yserve_usage() -> long {
    fs.write_text(FD_LOG, "yserve -- the Y language server (JSON-RPC 2.0 over stdio)\n\n"
        + "  --root DIR      the workspace root imports resolve against (default: cwd)\n"
        + "  --std-pack FILE compile the std units and write them to FILE, then exit\n"
        + "  --std-src       ignore an attached std pack and compile the units from source\n"
        + "  -W              the optional level-1 warnings, as `ycc -W`\n");
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
            let n = tonum(tail[:8]);
            if (tail[8:] == ys_pack_magic() && n > 0 && n <= size - 16) {
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
    let pack = native.std_pack(native.std_units(native.std_unit_names(), ""));
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
    let msg = json.jobj(parsed!);
    let id = dispatch.msg_id(msg);
    let method = dispatch.msg_method(msg);
    if (method == "") {
        // A response to a request this server never made, or garbage with no
        // method. If it carries an id, answer it, because an unanswered id is
        // what makes a client hang.
        if is_some(id) { out += serve.error_msg(id!, serve.E_INVALID_REQUEST, "no method in the message"); }
        return out;
    }
    let p = dispatch.msg_params(msg);
    if (!is_some(id)) {
        // A notification: no reply, whatever happens inside.
        out += dispatch.doc_notification(st, method, p);
    } else {
        let life = dispatch.lifecycle(st, id!, method);
        if is_some(life) {
            out += life!;
        } else if (!st.initialized) {
            // The protocol requires this refusal: the client has not sent
            // rootUri, so imports cannot be resolved, and any answer would use
            // the wrong base directory. LSP makes it a specific code, and a
            // client retries after it.
            out += dispatch.not_initialized(id!);
        } else {
            out += dispatch.doc_request(st, id!, method, p);
        }
    }
    out
}


// Claim the reply fd, once, before the first fork so every child inherits it.
// dup returns the new fd, or a negative errno.
def claim_reply_fd() -> long {
    let fd = syscall(32, FD_OUT, FD_REPLY, 0);
    if (fd > 0) { fd } else { FD_OUT }
}

// The loop. Reads frames until stdin ends or `exit` arrives.
def serve_loop(st: State, fd_in: long) -> long {
    let reply = claim_reply_fd();
    let r = rpc.in_new();
    let go = true;
    let code = 0;
    while (go) {
        let got = rpc.read_frame(r, fd_in);
        if (!is_some(got)) {
            // Clean end of input: the client closed the connection. Exiting 0
            // here is right -- this is how a client says "I am done", and the
            // LSP spec says the server should not treat it as an error.
            go = false;
        } else {
            let raw = got!;

            // The parent's own work: record what this message changed. Done
            // BEFORE the fork so the child inherits an up-to-date view, and done
            // in the parent because a child's writes die with it (dispatch.y
            // apply_state). Nothing here can exit -- see the note there.
            let leaving = dispatch.apply_state(st, raw);
            if (leaving) {
                // `exit` is a notification: no reply, and the client is done.
                go = false;
            } else {
            let child = fork {
                // Point this process's stdout at stderr FIRST, so anything the
                // compiler prints -- an import it cannot open, a trap message --
                // lands in the client's log instead of in the framed stream.
                syscall(33, FD_LOG, FD_OUT, 0);
                let bodies = handle_one(st, raw);
                let k = 0;
                while (k < len(bodies)) {
                    rpc.write_frame(reply, bodies[k]);
                    k = k + 1;
                }
                // exit_group(0): the child must not return into the runtime's
                // normal exit path, which would flush the parent's buffers and
                // run atexit handlers twice.
                syscall(60, 0);
                0
            };
            if (child > 0) {
                // The pid, or -errno. A negative result is a fork failure, not a
                // child: there is nothing to wait for, and the loop must not
                // spin forever on a resource limit.
                let status = wait_pid(child);
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
                rpc.write_frame(reply, serve.error_msg(json.nul(), serve.E_INTERNAL, "cannot fork a request handler"));
                go = false;
                code = 1;
            }
            }
        }
    }
    code
}

def serve_main() -> long {
    let o = parse_opts(argv());
    if (o.pack_out != "") {
        // A build step, not a request: write the pack and stop. Nothing is
        // served, so no frame is written and stdout stays empty.
        let rc = ys_write_pack(o.pack_out);
        return rc;
    }
    let pack = "";
    if (o.use_pack) { pack = ys_self_pack(); }
    let st = serve.server_state(o.root, pack, o.wlevel);
    serve_loop(st, FD_IN)
}

// The entry point. A `def main` is just a function: Y has no implicit call, so
// this last line is what starts the server.
let code = serve_main();