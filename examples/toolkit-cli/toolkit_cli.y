// toolkit_cli.y -- a JSON / CSV / base64 conversion toolkit.
//
// Reads stdin or a file, writes stdout, one job per invocation, so it
// composes in a pipe:  toolkit_cli csv --op=to-json < in.csv > out.json
//
// Everything time- or randomness-dependent is behind an explicit flag, and
// there is none: the default paths are pure functions of their input, so
// two runs produce identical bytes.
//
// ── exit codes ────────────────────────────────────────────────────────────
//
//   0  it worked
//   1  bad INPUT: a malformed document, a table that does not match its
//      header, a file that is not there, a path that does not resolve
//   2  bad USAGE: an unknown command, an unknown or misused flag, a value
//      that is not what the flag wants
//
// 1 and 2 are different on purpose: a script can tell "the data is broken"
// from "you asked wrongly". Every message goes to STDERR and every trap is
// designed out -- a runtime trap prints to STDOUT in Y, so a trap would splice itself into the output instead of
// announcing itself, and in a pipe it would corrupt the next stage.
//
// ── modules ───────────────────────────────────────────────────────────────
//
// args    vendored from examples/_toolkit/, unmodified
// b64.y     RFC 4648 encode and decode, both written here
// csvio.y   RFC 4180 parse and emit, plus the two JSON bridges
// jsonval.y the JSON value, a strict parser, a deterministic emitter
// selftest.y the property checks

// The two sample documents, embedded so the folder is self-contained: the
// demo below needs no file argument and no sibling folder. `embed` turns
// the bytes into a const string and its path is resolved at compile time
// relative to THIS file, so data/demo.json is found beside it.
embed DEMO_JSON from "data/demo.json";
embed DEMO_CSV from "data/demo.csv";

import args;
import b64;
import crypto;
import csvio;
import fs;
import jsonval;
import selftest;

// ── diagnostics ───────────────────────────────────────────────────────────
//
// One shape for every message: the tool's name, then what happened. `die`
// is the only way this program exits with a failure code, so there is
// exactly one place to look for the convention.

const PROG = "toolkit_cli";

def die(code: long, msg: str) {
    eputs(PROG + ": " + msg + "\n");
    exit(code)
};

def usage_err(msg: str) { die(2, msg + "  (try '" + PROG + " --help')") };
def data_err(msg: str) { die(1, msg) };

// emit(s: str) -- write s to stdout EXACTLY: no newline added, none
// removed. `print` would append one and `.trim()` would strip the trailing
// one, which matters because a CSV record's separator and a base64 line's
// newline are part of the output. One write(2) for the whole body also
// keeps a large document to a single syscall.
def emit(s: str) {
    if (len(s) > 0) { syscall(1, 1, s, len(s)) }
};

// ── the option spec ───────────────────────────────────────────────────────

const OPTS: [args.Opt] = [
    { long: "op",        short: "m", kind: args.STR,  help: "what to do; per command, see the command list below" },
    { long: "indent",    short: "i", kind: args.NUM,  help: "json/csv: indent width, 0..16 (default 2)" },
    { long: "path",      short: "p", kind: args.STR,  help: "json: the dotted path for --op=get/--op=text, e.g. a.b[2]" },
    { long: "sort-keys", short: "s", kind: args.BOOL, help: "json: emit object keys sorted instead of in input order" },
    { long: "delim",     short: "d", kind: args.STR,  help: "csv: field delimiter: one character, or comma|tab|semi|pipe|colon|space (default comma)" },
    { long: "line-end",  short: "e", kind: args.STR,  help: "csv: record separator, lf or crlf (default crlf, per RFC 4180)" },
    { long: "header",    short: "H", kind: args.BOOL, help: "csv: the first record names the columns" },
    { long: "num",       short: "N", kind: args.BOOL, help: "csv --op=to-json: a field that is exactly a JSON number becomes one" },
    { long: "quote-all", short: "A", kind: args.BOOL, help: "csv --op=from-json: quote every field, not only the ones that need it" },
    { long: "wrap",      short: "w", kind: args.NUM,  help: "base64 --op=encode: break every N characters (default 0, one line)" },
    { long: "lenient",   short: "l", kind: args.BOOL, help: "base64 --op=decode: skip characters outside the alphabet instead of failing" },
    { long: "checksum",  short: "c", kind: args.STR,  help: "base64 --op=sum: sha256 or sha512 (default sha256)" },
    { long: "stats",     short: "S", kind: args.BOOL, help: "print a one-line summary to stderr" },
    { long: "version",   short: "V", kind: args.BOOL, help: "print the version and exit" }
];

// ── input ─────────────────────────────────────────────────────────────────

// read_all_stdin() -> str -- everything on fd 0. A fixed buffer, reused,
// because nothing is ever freed and an allocation per read is a leak.
// `syscall(1, 1, s, 0)` writes nothing, so the length is computed here
// rather than trusted.
def read_all_stdin() -> str {
    let buf: [byte; 65536] = [0; 65536];
    let out: [byte] = [];
    let go = true;
    while (go) {
        let n = syscall(0, 0, &buf[0], 65536);
        if (n > 0) {
            let k = 0;
            while (k < n) { out += buf[k]; k = k + 1; };
        } else { go = false; }
    };
    from_bytes(out)
};

// read_input(path: str) -> str -- the file, or stdin for "" and "-".
def read_input(path: str) -> str {
    let r = "";
    if (path == "" || path == "-") {
        r = read_all_stdin()
    } else {
        let got = fs.read_file(path);
        if (is_some(got)) { r = unwrap(got); } else { die(1, "cannot read " + path) };
    };
    r
};

// ── shared flag checks ────────────────────────────────────────────────────

// need(op: str, cmd: str, names: [str]) -- the operation must be one this
// command implements, and the message lists the ones it does.
def need(op: str, cmd: str, names: [str]) {
    let good = false;
    let list = "";
    let i = 0;
    while (i < len(names)) {
        if (names[i] == op) { good = true; };
        if (i > 0) { list += " "; };
        list += names[i];
        i = i + 1
    };
    if (!good) {
        usage_err("--op=" + op + " is not a " + cmd + " operation; it is one of: " + list)
    }
};

const ALL_FLAGS: [str] = ["indent", "path", "sort-keys", "delim", "line-end", "header",
                          "num", "quote-all", "wrap", "lenient", "checksum", "stats"];

// no_foreign(cmd: str, mine: [str]) -- a flag that belongs to another
// command is a typo worth reporting, not something to ignore in silence.
// This is the difference between a CLI that catches your mistake and one
// that quietly does what it guessed.
def no_foreign(cmd: str, mine: [str]) {
    let i = 0;
    while (i < len(ALL_FLAGS)) {
        let name = ALL_FLAGS[i];
        let is_mine = false;
        let k = 0;
        while (k < len(mine)) { if (mine[k] == name) { is_mine = true; }; k = k + 1; };
        if (args.has(name) && !is_mine) {
            usage_err("--" + name + " is not a " + cmd + " option")
        };
        i = i + 1
    }
};

// want_indent() -> long -- the indent, bounds-checked. `--indent=-1` is
// accepted by the flag parser (it is a whole number) and refused here,
// which is where the meaning lives.
def want_indent() -> long {
    let n = args.get_long("indent", 2);
    if (n < 0 || n > 16) { usage_err("--indent must be 0..16, got " + tostring(n)) };
    n
};

// ── json ──────────────────────────────────────────────────────────────────

def cmd_json(path: str) {
    let op = args.get_str("op", "pretty");
    need(op, "json", ["pretty", "compact", "validate", "get", "text", "keys"]);
    no_foreign("json", ["indent", "path", "sort-keys", "stats"]);
    let ind = want_indent();
    let sorted = args.has("sort-keys");
    let want_path = args.get_str("path", "");

    let src = read_input(path);
    let v = jsonval.parse(src);
    let e = jsonval.parse_err();
    if (e != "") { data_err("not JSON: " + e) };
    // --op=get, --op=text and --op=keys all read through --path, so a
    // lookup does not need a second command.
    let root = v;
    if (want_path != "" && op != "get") {
        let here = jsonval.lookup(v, want_path);
        if (is_some(here)) { root = unwrap(here); } else { data_err("--path=" + want_path + ": " + jsonval.q_err) };
    };

    let body = "";
    if (op == "validate") {
        // Parse only. Silence on success is the Unix answer, and it is what
        // makes `toolkit_cli json --op=validate f.json && next` work.
        body = "";
    } else if (op == "get") {
        if (want_path == "") { usage_err("--op=get needs --path, e.g. --path=a.b[2]") };
        let hit = jsonval.lookup(v, want_path);
        if (is_some(hit)) {
            let leaf = unwrap(hit);
            // A string comes out as a quoted JSON string so it composes
            // with --op=pretty; everything else comes out as JSON.
            if (leaf.kind == 3) { body = jsonval.esc_str(leaf.s) + "\n"; }
            else { body = jsonval.render(leaf, false, ind, sorted) + "\n"; };
        } else {
            data_err("--path=" + want_path + ": " + jsonval.q_err)
        }
    } else if (op == "text") {
        body = jsonval.scalar_text(root) + "\n"
    } else if (op == "keys") {
        if (root.kind != 5) { data_err("--op=keys wants an object, not " + jsonval.kind_name(root.kind)) };
        let i = 0;
        while (i < len(root.fields)) { body += root.fields[i].k + "\n"; i = i + 1; }
    } else {
        // pretty (the default) and compact are the same emitter with a
        // different setting, so they cannot drift apart.
        body = jsonval.render(v, op == "pretty", ind, sorted) + "\n"
    };
    if (args.has("stats")) {
        eputs(PROG + ": json: " + tostring(jsonval.node_count(v)) + " nodes, depth " +
              tostring(jsonval.max_depth(v)) + ", " + tostring(len(src)) + " bytes in, " +
              tostring(body.length) + " bytes out, heap " + tostring(heap_used()) + " bytes\n")
    };
    emit(body)
};

// ── csv ───────────────────────────────────────────────────────────────────

def cmd_csv(path: str) {
    let op = args.get_str("op", "to-json");
    need(op, "csv", ["to-json", "from-json"]);
    no_foreign("csv", ["delim", "line-end", "header", "num", "quote-all", "indent", "stats"]);
    let ind = want_indent();
    let dname = args.get_str("delim", ",");
    let delim = csvio.csv_delim(dname);
    if (delim < 0) {
        usage_err("--delim=" + dname + " is not one character and not one of comma|tab|semi|pipe|colon|space")
    };
    if (delim == 34 || delim == 10 || delim == 13) {
        usage_err("--delim cannot be a quote or a line break")
    };
    let le = args.get_str("line-end", "crlf");
    let eol = "\r\n";
    if (le == "lf") { eol = "\n"; } else if (le != "crlf") { usage_err("--line-end is lf or crlf, got " + le) };
    let header = args.has("header");
    let numbers = args.has("num");
    let always = args.has("quote-all");

    let src = read_input(path);
    let out = "";
    let rows = 0;
    let ncol = 0;
    if (op == "to-json") {
        let recs = csvio.csv_parse(src, delim);
        if (csvio.csv_err != "") { data_err("not CSV: " + csvio.csv_err) };
        let doc = csvio.csv_to_json(recs, header, numbers);
        if (is_some(doc)) {
            out = jsonval.render(unwrap(doc), true, ind, false) + "\n";
            rows = len(recs);
            ncol = if_ncol(recs)
        } else {
            data_err("not a usable CSV table: " + csvio.csv_err)
        }
    } else {
        let v = jsonval.parse(src);
        if (jsonval.parse_err() != "") { data_err("not JSON: " + jsonval.parse_err()) };
        let recs = csvio.json_to_csv(v, header);
        if (csvio.csv_err != "") { data_err("not a usable JSON table: " + csvio.csv_err) };
        out = csvio.csv_render(recs, delim, eol, always);
        rows = len(recs);
        ncol = if_ncol(recs)
    };
    if (args.has("stats")) {
        eputs(PROG + ": csv: " + tostring(rows) + " record(s) x " + tostring(ncol) +
              " field(s), delimiter " + csvio.csv_delim_name(delim) + ", " +
              tostring(src.length) + " bytes in, " + tostring(out.length) + " bytes out, heap " +
              tostring(heap_used()) + " bytes\n")
    };
    emit(out)
};

def if_ncol(rows: [[str]]) -> long {
    let n = 0;
    if (len(rows) > 0) { n = len(rows[0]); };
    n
};

// ── base64 ────────────────────────────────────────────────────────────────

def cmd_b64(path: str) {
    let op = args.get_str("op", "encode");
    need(op, "base64", ["encode", "decode", "sum"]);
    no_foreign("base64", ["wrap", "lenient", "checksum", "stats"]);
    let wrap = args.get_long("wrap", 0);
    if (wrap < 0 || wrap > 76) { usage_err("--wrap must be 0..76, got " + tostring(wrap)) };
    let sum = args.get_str("checksum", "sha256");
    let src = read_input(path);
    let out = "";
    if (op == "decode") {
        let got = b64.decode(src, args.has("lenient"));
        if (b64.dec_err != "") { data_err("not base64: " + b64.dec_err) };
        // The bytes go out as a str: a [byte] is not a valid syscall
        // argument (only long, bool, str and *T), and from_bytes is the
        // one conversion between them.
        out = from_bytes(got)
    } else if (op == "sum") {
        let b = bytes(src);
        if (sum == "sha256") {
            out = crypto.hex(crypto.sha256(b)) + "\n"
        } else if (sum == "sha512") {
            out = crypto.hex(crypto.sha512(b)) + "\n"
        } else {
            usage_err("--checksum is sha256 or sha512, got " + sum)
        }
    } else {
        out = b64.encode(bytes(src), wrap)
    };
    if (args.has("stats")) {
        eputs(PROG + ": base64: " + tostring(src.length) + " bytes in, " +
              tostring(out.length) + " bytes out, heap " + tostring(heap_used()) + " bytes\n")
    };
    emit(out)
};

// ── help ──────────────────────────────────────────────────────────────────

// The command list, as data rather than one long literal: a Y string has
// no `\uXXXX` and no line continuation, so a multi-line literal would have
// to be escaped by hand -- and `\<newline>` inserts a newline instead of
// continuing the line, which is the trap this shape avoids.
const HELP_LINES: [str] = [
    "commands (the first operand):",
    "  json       parse a JSON document and reformat, compact, validate,",
    "             query, or list keys",
    "  csv        convert CSV to JSON (--op=to-json, the default) or JSON to",
    "             CSV (--op=from-json)",
    "  base64     RFC 4648 encode (the default), decode, or checksum",
    "  selftest   run the built-in property checks: the RFC 4648 vectors,",
    "             the RFC 4180 cases, JSON round-trip identity, and every",
    "             malformed input run end to end through a forked child",
    "  demo       a worked example of every mode, on two documents",
    "             embedded in this binary -- no file arguments needed",
    "  help       this message",
    "  version    the version",
    "",
    "json --op:",
    "  pretty    reformat with newlines and indentation (the default)",
    "  compact   one line, no spaces",
    "  validate  parse only; silent on success, exit 1 with a diagnostic",
    "  get       print the value at --path, e.g. --path=a.b[2].c",
    "  text      print a scalar's text; on a container, a description of it",
    "  keys      print an object's keys, one per line, in input order",
    "",
    "csv --op:",
    "  to-json   records -> a JSON array. With --header the first record",
    "            names the keys and each record becomes an object; without",
    "            it every field is a JSON string and the document is an",
    "            array of arrays",
    "  from-json the reverse. With --header each element must be an object",
    "            and its keys give the columns; without it each must be an",
    "            array",
    "",
    "base64 --op:",
    "  encode    the input's bytes as base64 (the default)",
    "  decode    the input back to bytes; strict unless --lenient",
    "  sum       the checksum of the input's bytes, printed as hex",
    "",
    "reading and writing:",
    "  The FILE operand is read when given, otherwise stdin; '-' means",
    "  stdin explicitly. Output goes to stdout and every diagnostic to",
    "  stderr, so `2>err` keeps stdout clean for the next stage of a pipe.",
    "  --stats adds one summary line, on stderr.",
    "",
    "exit codes:",
    "  0  it worked",
    "  1  bad input: a malformed document, a table that does not match its",
    "     header, a file that is not there, a path that does not resolve",
    "  2  bad usage: an unknown command, an unknown or misused flag, a value",
    "     the flag will not accept",
    "",
    "determinism:",
    "  Object keys come out in INPUT ORDER, never sorted, unless",
    "  --sort-keys. Numbers keep the exact text they were written with, so",
    "  1.0 stays 1.0. Indentation is fixed by --indent. Nothing consults",
    "  the clock, a random source or the network, so two runs of the same",
    "  command produce identical bytes.",
    ""
];

const COMMANDS: [str] = ["json", "csv", "base64", "selftest", "demo", "help", "version"];

// Every option, so `selftest` can refuse all of them by name. args
// exposes `has` per option rather than "was anything given", so the check
// walks the list instead of asking one question.
const ALL_OPTS: [str] = ["op", "indent", "path", "sort-keys", "delim", "line-end",
                         "header", "num", "quote-all", "wrap", "lenient", "checksum",
                         "stats", "version"];

def cmd_help() {
    emit(args.usage());
    emit(join(HELP_LINES, "\n"))
};


// ── demo ──────────────────────────────────────────────────────────────────
//
// A worked example of every mode, over two documents embedded in the
// binary. This is the run= line in gate.conf: it is the documented
// deterministic invocation, so its bytes are what EXPECTED holds, and
// because it is one process with two embedded inputs it is also the proof
// that the folder builds and runs with no sibling present.
//
// Every step goes through the SAME functions the real commands use --
// nothing here is a shortcut, so if the demo works the commands work.

def demo_head(n: long, what: str, cmd: str) {
    emit("[" + tostring(n) + "] " + what + "\n    $ toolkit_cli " + cmd + "\n")
};

def cmd_demo() {
    emit("toolkit_cli demo -- every mode, on two documents embedded in this binary\n");
    emit("data/demo.json is " + tostring(len(DEMO_JSON)) + " bytes; " +
         "data/demo.csv is " + tostring(len(DEMO_CSV)) + " bytes.\n");

    // -- the JSON side --------------------------------------------------
    let v = jsonval.parse(DEMO_JSON);
    if (jsonval.parse_err() != "") { data_err("data/demo.json does not parse: " + jsonval.parse_err()) };

    demo_head(1, "json --op=pretty: 2-space indent, keys in INPUT order, no sorting", "json --op=pretty data/demo.json");
    emit(jsonval.render(v, true, 2, false) + "\n");

    demo_head(2, "json --op=compact: one line, byte-identical on every run", "json --op=compact data/demo.json");
    emit(jsonval.render(v, false, 2, false) + "\n");

    demo_head(3, "json --op=keys: the root's keys, in input order", "json --op=keys data/demo.json");
    let i = 0;
    while (i < len(v.fields)) { emit("  " + v.fields[i].k + "\n"); i = i + 1; };

    demo_head(4, "json --op=get: a dotted path into a nested array of objects", "json --op=get --path=authors[0].name data/demo.json");
    let q = jsonval.lookup(v, "authors[0].name");
    emit(jsonval.esc_str(unwrap(q).s) + "\n");
    demo_head(5, "json --op=get: the same document's numbers, verbatim", "json --op=compact --path=numbers data/demo.json");
    let q2 = jsonval.lookup(v, "numbers");
    emit(jsonval.render(unwrap(q2), false, 2, false) + "\n");

    demo_head(6, "json --sort-keys: the SAME document with its keys sorted", "json --op=keys --sort-keys data/demo.json");
    let sorted = jsonval.render(v, false, 2, true);
    emit(sorted[0:120] + "\n  ...\n");

    demo_head(7, "json --op=stats (stderr): shape of the document", "json --op=validate --stats data/demo.json");
    emit("  " + tostring(jsonval.node_count(v)) + " nodes, depth " + tostring(jsonval.max_depth(v)) +
         ", " + tostring(len(DEMO_JSON)) + " bytes in\n");

    // -- the CSV side ---------------------------------------------------
    demo_head(8, "csv --op=to-json --header: the first record names the columns", "csv --op=to-json --header data/demo.csv");
    let recs = csvio.csv_parse(DEMO_CSV, 44);
    if (csvio.csv_err != "") { data_err("data/demo.csv does not parse: " + csvio.csv_err) };
    let doc = csvio.csv_to_json(recs, true, false);
    let jtxt = jsonval.render(unwrap(doc), true, 2, false);
    emit(jtxt + "\n");

    demo_head(9, "csv -> json -> csv: byte-identical to data/demo.csv", "csv --op=from-json --header --line-end=lf");
    // The reverse step reads the ARRAY-OF-ARRAYS form, so the header row
    // is still there and comes back out as the header. That is what makes
    // this a round trip rather than two half-conversions.
    let all = csvio.csv_to_json(recs, false, false);
    let back = csvio.csv_render(csvio.json_to_csv(unwrap(all), true), 44, "\n", false);
    emit(back);
    emit("  identical to the input file: " + tostring(back == DEMO_CSV) + "\n");

    demo_head(10, "csv --op=to-json --num: fields that are JSON numbers become numbers", "csv --op=to-json --header --num");
    let recs2 = csvio.csv_parse("n,f\n1,1.5\n007,x\n", 44);
    emit(jsonval.render(unwrap(csvio.csv_to_json(recs2, true, true)), false, 2, false) + "\n");
    emit("  007 stays a string: a leading zero is not a JSON number\n");

    // -- the base64 side ------------------------------------------------
    demo_head(11, "base64: the RFC 4648 section 10 vectors, encoded here", "base64 --op=encode");
    let vecs: [str] = ["", "f", "fo", "foo", "foob", "fooba", "foobar"];
    i = 0;
    while (i < len(vecs)) {
        let enc = b64.encode(bytes(vecs[i]), 0);
        emit("  " + pad(vecs[i], 8) + " -> " + (enc == "" ? "(nothing)" : trimnl(enc)) + "\n");
        i = i + 1
    };

    demo_head(12, "base64 --op=sum: SHA-256 of data/demo.csv, against `sha256sum`", "base64 --op=sum --checksum=sha256 data/demo.csv");
    emit(crypto.hex(crypto.sha256(bytes(DEMO_CSV))) + "\n");
    demo_head(13, "base64 --op=sum --checksum=sha512, of the same bytes", "base64 --op=sum --checksum=sha512 data/demo.csv");
    emit(crypto.hex(crypto.sha512(bytes(DEMO_CSV))) + "\n");

    demo_head(14, "base64 --op=decode: the demo CSV back out of its own encoding", "base64 --op=decode");
    let rt = b64.decode(b64.encode(bytes(DEMO_CSV), 0), false);
    emit("  " + tostring(len(rt)) + " bytes, identical to the input: " +
         tostring(from_bytes(rt) == DEMO_CSV) + "\n");

    emit("\nEvery step above is the same code the real commands run. The exit\n");
    emit("codes and the malformed-input paths are what `toolkit_cli selftest`\n");
    emit("checks, by running this binary end to end through a forked child.\n")
};

// pad(s: str, n: long) -> str -- s left-justified to n columns, for the
// table above. `pad_right` exists as a string method; this is only here so
// the alignment cannot depend on option order.
def pad(s: str, n: long) -> str { s.pad_right(n, " ") };

def trimnl(s: str) -> str {
    let r = s;
    if (r.length > 0 && byte_at(r, r.length - 1) == 10) { r = r[0:r.length - 1]; };
    r
};

const VERSION = "toolkit_cli 1.0 (examples/toolkit-cli)\n";

// ── main ──────────────────────────────────────────────────────────────────

def main() {
    args.init(PROG, "JSON, CSV and base64 conversion from the shell", OPTS, "<command> [FILE|-]");
    args.parse_or_exit(argv());
    let pos = args.positional();
    if (args.has("version")) { emit(VERSION); exit(0) };
    if (len(pos) == 0) {
        eputs(args.usage());
        eputs(join(HELP_LINES, "\n"));
        exit(2)
    };
    let cmd = pos[0];
    let known = false;
    let i = 0;
    while (i < len(COMMANDS)) { if (COMMANDS[i] == cmd) { known = true; }; i = i + 1; };
    if (!known) {
        eputs(PROG + ": unknown command '" + cmd + "'\n");
        eputs(PROG + ": the commands are: json, csv, base64, selftest, demo, help, version\n");
        exit(2)
    };
    let file = "";
    if (len(pos) > 1) { file = pos[1] };
    if (len(pos) > 2) {
        usage_err("too many operands: expected at most one FILE, got " + tostring(len(pos) - 1))
    };
    if (cmd == "help") {
        cmd_help()
    } else if (cmd == "version") {
        emit(VERSION)
    } else if (cmd == "selftest") {
        if (file != "") { usage_err("selftest takes no FILE") };
        let oi = 0;
        while (oi < len(ALL_OPTS)) {
            if (args.has(ALL_OPTS[oi])) { usage_err("selftest takes no --" + ALL_OPTS[oi]) };
            oi = oi + 1;
        };
        if (selftest.run() != 0) { exit(1) }
    } else if (cmd == "json") {
        cmd_json(file)
    } else if (cmd == "csv") {
        cmd_csv(file)
    } else if (cmd == "base64") {
        cmd_b64(file)
    } else if (cmd == "demo") {
        if (file != "") { usage_err("demo takes no FILE") };
        let di = 0;
        while (di < len(ALL_OPTS)) {
            if (args.has(ALL_OPTS[di])) { usage_err("demo takes no --" + ALL_OPTS[di]) };
            di = di + 1;
        };
        cmd_demo()
    }
};

main();