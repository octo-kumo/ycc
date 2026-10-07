// dispatch.y -- one JSON-RPC message in, the frames to send back out.
//
// Split from serve.y so the protocol can be tested without a pipe: every
// function here takes a message STRING and returns a STRING, so a fixture can
// hand-feed a whole conversation and read the answers. The main loop in yserve.y
// is then only framing, fork and write.
//
// Two rules shape everything below.
//
//   A notification gets no reply, ever. The protocol says so, and a client that
//   receives a reply to `textDocument/didChange` counts it as a desync and may
//   drop the connection. So the id is looked up FIRST: present means a request,
//   absent means a notification, and the two paths are separate from there on.
//
//   A handler returns a LIST because one message can produce more than one
//   frame: didChange answers with a publishDiagnostics notification, and a
//   request may push diagnostics for an import it touched before its own result.
//   Keeping the frames in an explicit list is what stops those two from
//   interleaving on stdout.

import json;

import serve from "./serve.y";

// ── the parent's half ──────────────────────────────────────────────────

// Update the server's own state from a message, and say whether the loop should
// stop. This is the ONLY message handling that runs in the parent, and it is
// kept to what the parent must remember:
//
//   * which documents are open, and their text and version
//   * whether initialize has been answered
//   * whether exit has arrived
//
// Everything else -- the checker, the linter, the formatter, building the reply
// -- happens in a forked child. The reason is the fork itself: a child gets a
// COPY of the parent's memory, so any state a CHILD wrote would be gone by the
// next message. State the server must remember across messages therefore has to
// be written here, in the parent, before the child is created.
//
// It is safe here because nothing in this function can exit: json.parse is
// tolerant (it returns none rather than raising), and the rest is field reads
// and map assignments. That is the property that makes fork-per-request work at
// all -- the parent must be unkillable, and this is the only code it runs.
//
// Returns true when the client has sent `exit` and the loop should stop.
def apply_state(st: State, raw: str) -> bool {
    let parsed = json.parse(raw);
    if (!is_some(parsed)) { return false; }
    let msg = json.jobj(parsed !);
    let method = msg_method(msg);
    let p = msg_params(msg);
    if (method == "initialize") {
        st.initialized = true;
        // R1.8's `checkOnChange`, read HERE and not in `do_initialize`, and the
        // placement is the whole reason this took two attempts.
        //
        // The server forks per request: the parent records what must survive, the
        // child answers from a COPY and dies (LSP.md section 4.2). So a flag set
        // in `do_initialize` lives in the child that read it, and the next
        // keystroke gets a server that has forgotten it -- which is exactly what
        // happened: the client said `false`, the child honoured it, and the
        // session still published on every change. This function is the only code
        // the parent runs, so this is the only place the setting can be recorded.
        st.check_on_change = serve.read_check_on_change(p);
        // Same placement, same reason: the per-request timing lines are written by
        // the CHILDREN, so the flag has to be on the parent's State for them to
        // inherit it.
        st.timing = serve.read_timing(p);
    }
    else if (method == "shutdown") { st.shutting = true; }
    else if (method == "exit") { serve.on_exit(st); }
    else if (method == "textDocument/didOpen") { serve.note_open(st, p); }
    else if (method == "textDocument/didChange") { serve.note_change(st, p); }
    else if (method == "textDocument/didClose") { serve.note_close(st, p); }
    else if (method == "workspace/didChangeWatchedFiles") {
        // An import may have been created or deleted on disk, which changes what
        // the open documents resolve to. Nothing is stored; the documents
        // already hold their text. What this needs is a re-check, which is the
        // child's job.
    } else { };
    st.exiting
}

// ── classifying a message ───────────────────────────────────────────────

// A request's id, or none for a notification. `id: null` is legal JSON-RPC and
// is how a client sends a notification-shaped thing that expects no answer --
// so a null id counts as absent, which is the safe reading.
def msg_id(msg: json.Val) -> json.Val? {
    let out: json.Val? = none;
    if let json.JObj j = msg {
        let m = j.members;
        let got = m["id"];
        if is_some(got) {
            let v = got !;
            if (!json.is_null(v)) { out = some(v); }
        }
    };
    out
}

def msg_method(msg: json.Val) -> str {
    let name = "";
    if let json.JObj j = msg {
        let m = j.members;
        let got = m["method"];
        if is_some(got) {
            let v = got !;
            let t = json.as_str(v);
            if is_some(t) { name = t !; }
        }
    };
    name
}

def msg_params(msg: json.Val) -> { str => json.Val } {
    let out: { str => json.Val } = {};
    if let json.JObj j = msg {
        let m = j.members;
        let got = m["params"];
        if is_some(got) { out = serve.members_of(got !); }
    };
    out
}

// ── notifications ───────────────────────────────────────────────────────

// What a document notification answers with. An unknown document produces no
// frame: a client that sends didChange for a file it has not opened has a bug,
// and inventing an empty diagnostics list for it would only make the bug harder
// to see from this side.
//
// The reply is a LIST because one message can produce several notifications: a
// buffer whose findings span the file and an import produces one
// publishDiagnostics per file (serve.publish_for), and they must not interleave.
def doc_notification(st: State, method: str, p: { str => json.Val }) -> [str] {
    let out: [str] = [];
    let reply: [str] = [];
    if (method == "textDocument/didOpen") { reply = serve.on_did_open(st, p); }
    else if (method == "textDocument/didChange") { reply = serve.on_did_change(st, p); }
    else if (method == "textDocument/didSave") { reply = serve.on_did_save(st, p); }
    else if (method == "textDocument/didClose") { reply = serve.on_did_close(st, p); }
    else if (method == "initialized") { }
    else if (method == "exit") { serve.on_exit(st); }
    else if (method == "workspace/didChangeConfiguration") { }
    else if (method == "workspace/didChangeWatchedFiles") {
        // An import may have been created or deleted on disk, which changes what
        // the open documents resolve to. Re-checking them all is the honest
        // response; the alternative -- waiting for the next keystroke -- means
        // the editor shows a stale error until the user types.
        reply += recheck_all(st);
    } else if (method == "$/cancelRequest") {
        // Cancellations are answered by ignoring them. A checker walk finishes in
        // single-digit milliseconds, so a cancelled request is almost always
        // already done; and LSP explicitly permits a server to reply to a
        // cancelled request with the real result if it cannot stop.
    } else if (method == "$/setTrace") {
        // Trace is accepted and discarded: it is how a client turns on verbose
        // logging, and a server that errors on it cannot be debugged by the one
        // tool the protocol gives for that.
    } else {
        // An unknown NOTIFICATION is silently ignored, per the spec. Erroring
        // would start a reply the client is not waiting for.
    }
    out += reply;
    out
}

// Re-check every open document, publishing each. The frames are independent
// notifications and a client applies them in arrival order, so concatenating
// them into one write is safe and saves a write per document.
def recheck_all(st: State) -> [str] {
    let out: [str] = [];
    foreach (uri in st.open) {
        out += serve.refresh(st, uri);
    }
    out
}

// ── requests ────────────────────────────────────────────────────────────

// A request's answer, as a frame. `id` is echoed unchanged: a client's id is an
// opaque token and coercing it (a number as a string, say) makes the reply
// unmatchable.
def doc_request(st: State, id: json.Val, method: str, p: { str => json.Val }) -> str {
    let out = "";
    if (method == "textDocument/formatting") {
        out = serve.do_formatting(st, id, p);
    } else if (method == "textDocument/semanticTokens/full") {
        out = serve.do_semantic_tokens(st, id, p);
    } else if (method == "textDocument/semanticTokens/range") {
        // The OTHER half of `range: true`, and the half that actually gets used.
        //
        // There are TWO methods, not one with an optional argument:
        // `semanticTokens/full` and `semanticTokens/range`. Advertising
        // `range: true` is what makes a client send the second one -- it is how the
        // client asks for a viewport instead of a document. This server implemented
        // the range as an optional `range` on `/full` and did NOT route `/range`, so
        // every viewport request came back `-32601 unsupported request` and the
        // client fell back to the whole document: the 400KB response the range was
        // added to avoid. A real client log reads
        //
        //     Request textDocument/semanticTokens/range failed.
        //       Message: unsupported request: textDocument/semanticTokens/range
        //
        // on every viewport change.
        //
        // The handler is the same one: its parameters are `{ textDocument, range }`
        // and it already reads `range` when present. So this is a route, not a second
        // implementation.
        out = serve.do_semantic_tokens(st, id, p);
    } else if (method == "textDocument/documentSymbol") {
        out = serve.do_document_symbols(st, id, p);
    } else if (method == "textDocument/definition") {
        out = serve.do_definition(st, id, p);
    } else if (method == "textDocument/hover") {
        out = serve.do_hover(st, id, p);
    } else if (method == "textDocument/completion") {
        out = serve.do_completion(st, id, p);
    } else if (method == "textDocument/rangeFormatting") {
        // Declared unsupported in the capabilities, so this only arrives from a
        // client ignoring them. Answering with an error is honest; formatting the
        // range and pretending is not.
        out = serve.error_msg(id, serve.E_INVALID_PARAMS, "range formatting is not supported");
    } else {
        out = serve.error_msg(id, serve.E_METHOD_NOT_FOUND, "unsupported request: " + method);
    }
    out
}

// The two lifecycle requests, handled before anything else: `initialize` must
// work before the client is allowed to send anything else, and `shutdown` must
// work after everything has stopped.
def lifecycle(st: State, id: json.Val, method: str) -> str? {
    let out: str? = none;
    if (method == "initialize") {
        out = some(serve.do_initialize(st, id));
    } else if (method == "shutdown") {
        st.shutting = true;
        out = some(serve.do_shutdown(id));
    };
    out
}

// A request before `initialize` is an error, not a guess: the client has not
// sent its rootUri, so imports could not be resolved, and answering anyway would
// produce diagnostics with the wrong base directory. LSP makes this a specific
// error code and clients retry after it.
def not_initialized(id: json.Val) -> str {
    serve.error_msg(id, serve.E_NOT_INITIALIZED, "the server has not been initialized")
}

export {
    apply_state,
    msg_id, msg_method, msg_params,
    doc_notification, doc_request, lifecycle, not_initialized, recheck_all
};
