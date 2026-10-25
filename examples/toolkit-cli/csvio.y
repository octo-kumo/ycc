// csv.y -- RFC 4180 CSV, parsed and emitted, plus the two JSON bridges.
//
// ── trap 2, and why this file never calls split() ─────────────────────────
//
// `s.split(sep)` DROPS EXACTLY ONE TRAILING EMPTY FIELD: "a,".split(",") is [a], ",a".split(",") is ["", a]. CSV is nothing
// but that case -- `a,b,` has THREE fields and a trailing empty field is a
// field, not an absence. So the record and field splitting here is a
// character scanner with its own state, and split() appears nowhere in this
// file. The cases that matter, and what this parser returns:
//
//   ""       -> []                no bytes, no record
//   "\n"     -> []                a blank line is not a record
//   "a,b,"   -> [["a","b",""]]    the trailing empty field survives
//   "a,,b"   -> [["a","","b"]]    a doubled delimiter is two fields
//   "\"\""   -> [[""]]            a quoted empty field is a field
//
// ── quoting ───────────────────────────────────────────────────────────────
//
// Emitting quotes a field exactly when it has to: it contains the
// delimiter, a quote, CR or LF -- or when --quote-all is given. Inside a
// quoted field a quote is doubled. Nothing else is quoted, so `hello` and
// ` hello ` come out bare: whitespace is data in CSV.

import b64;
import jsonval;

// For its alias JVal. A `type` alias on an imported record keeps the
// signatures below readable; the import is by BARE name, which is what makes the qualified form work at all.
type JVal = jsonval.JVal;

// ── the delimiter ──────────────────────────────────────────────────────────

// csv_delim(s: str) -> long -- a delimiter named on the command line, or
// -1 when the name is not one this tool knows. A single character is its
// own name; the words are conveniences for shells that fight over commas.
def csv_delim(s: str) -> long {
    let d = 0 - 1;
    if (s == "comma") { d = 44; }
    else if (s == "tab") { d = 9; }
    else if (s == "semi" || s == "semicolon") { d = 59; }
    else if (s == "pipe") { d = 124; }
    else if (s == "colon") { d = 58; }
    else if (s == "space") { d = 32; }
    else if (s == "\\t") { d = 9; }
    else if (len(s) == 1) { d = byte_at(s, 0); };
    d
};

// csv_delim_name(d: long) -> str -- for a diagnostic and for --help.
def csv_delim_name(d: long) -> str {
    let s = "byte " + tostring(d);
    if (d == 44) { s = "','"; }
    else if (d == 9) { s = "TAB"; }
    else if (d == 59) { s = "';'"; }
    else if (d == 124) { s = "'|'"; }
    else if (d == 58) { s = "':'"; }
    else if (d == 32) { s = "SPACE"; }
    else if (d == 34) { s = "a quote"; };
    s
};

// ── parsing ────────────────────────────────────────────────────────────────
//
// The scanner's state is module level so the loop body can read it without
// threading a record through every arm; csv_err is read by the caller
// after csv_parse returns.

let csv_err = "";
let csv_rec = 0;         // the 1-based record the scanner is inside
let csv_col = 0;         // the 1-based field within it

def fail_c(msg: str) { csv_err = msg; };

// crlf_step(s: str, i: long, c: long) -> long -- how far to advance past a
// record terminator: CRLF is two bytes, a bare CR or LF is one. A CRLF
// therefore never yields two records.
def crlf_step(s: str, i: long, c: long) -> long {
    let step = 1;
    if (c == 13 && i + 1 < len(s) && byte_at(s, i + 1) == 10) { step = 2; };
    step
};

// csv_parse(s: str, delim: long) -> [[str]]
//
// One loop, three states -- plain text, inside a quoted field, and just
// after a closing quote -- written in the positive-condition style because
// Y has no `continue` and no `break`. A CR or LF
// INSIDE quotes is data, which is the whole reason a scanner is needed.
def csv_parse(s: str, delim: long) -> [[str]] {
    csv_err = "";
    csv_rec = 1;
    csv_col = 1;
    let rows: [[str]] = [];
    let fields: [str] = [];
    let cur = "";
    let n = len(s);
    let in_q = false;
    let after_q = false;
    let row_len = 0;
    let i = 0;
    let go = true;
    while (go) {
        // NOTE: byte_at is bounds checked, so the end of input has to be
        // tested rather than read -- `byte_at(s, len(s))` traps. Every
        // scan loop in this example does this.
        let c = 0 - 1;
        if (i < n) { c = byte_at(s, i); };
        if (c < 0) {
            if (in_q) {
                // RFC 4180 has no way to spell a record that stops inside a
                // quoted field, so this is an error, not a guess.
                fail_c("record " + tostring(csv_rec) + " field " + tostring(csv_col) +
                       ": a quoted field is never closed before the end of the input");
                go = false;
            } else {
                // Flush the last line, but only if it held any bytes: a
                // trailing newline must not invent an empty final record.
                if (row_len > 0 || len(fields) > 0) {
                    fields += cur;
                    rows += fields
                };
                go = false;
            };
        } else if (in_q) {
            if (c == 34) {
                // A doubled quote is one literal quote; a single one closes.
                if (i + 1 < n && byte_at(s, i + 1) == 34) {
                    cur += "\"";
                    i = i + 2;
                } else {
                    in_q = false;
                    after_q = true;
                    i = i + 1;
                }
            } else {
                cur += chr(c);
                row_len = row_len + 1;
                i = i + 1;
            };
        } else if (after_q) {
            if (c == delim) {
                fields += cur;
                cur = "";
                after_q = false;
                csv_col = csv_col + 1;
                row_len = row_len + 1;
                i = i + 1;
            } else if (c == 10 || c == 13) {
                fields += cur;
                if (row_len > 0) { rows += fields };
                fields = [];
                cur = "";
                after_q = false;
                csv_col = 1;
                row_len = 0;
                csv_rec = csv_rec + 1;
                i = i + crlf_step(s, i, c);
            } else if (c == 32 || c == 9) {
                i = i + 1;      // space after a closing quote is not data
            } else {
                fail_c("record " + tostring(csv_rec) + " field " + tostring(csv_col) +
                       ": " + b64.t_byte(c) + " after the closing quote");
                go = false;
            };
        } else if (c == 34) {
            if (cur != "") {
                fail_c("record " + tostring(csv_rec) + " field " + tostring(csv_col) +
                       ": a quote may only open a field, not appear inside one");
                go = false;
            } else {
                in_q = true;
                row_len = row_len + 1;
                i = i + 1;
            };
        } else if (c == delim) {
            fields += cur;
            cur = "";
            csv_col = csv_col + 1;
            row_len = row_len + 1;
            i = i + 1;
        } else if (c == 10 || c == 13) {
            fields += cur;
            if (row_len > 0) { rows += fields };
            fields = [];
            cur = "";
            csv_col = 1;
            row_len = 0;
            csv_rec = csv_rec + 1;
            i = i + crlf_step(s, i, c);
        } else {
            cur += chr(c);
            row_len = row_len + 1;
            i = i + 1;
        };
    };
    rows
};

// ── emitting ──────────────────────────────────────────────────────────────

// csv_quote(f: str, delim: long, always: bool) -> str -- one field, quoted
// only when it has to be.
def csv_quote(f: str, delim: long, always: bool) -> str {
    let need = always;
    let i = 0;
    let n = len(f);
    let go = i < n;
    while (go) {
        let c = byte_at(f, i);
        if (c == delim || c == 34 || c == 10 || c == 13) { need = true; };
        i = i + 1;
        go = i < n && !need;
    };
    if (!need) {
        f
    } else {
        let out = "\"";
        let j = 0;
        let m = len(f);
        while (j < m) {
            let c = byte_at(f, j);
            if (c == 34) { out += "\"\""; } else { out += chr(c); };
            j = j + 1;
        };
        out += "\""
    }
};

// csv_render(rows: [[str]], delim: long, eol: str, always: bool) -> str
// Every record gets a terminator, including the last, so the output is one
// unambiguous document rather than a guess about the reader.
def csv_render(rows: [[str]], delim: long, eol: str, always: bool) -> str {
    let out = "";
    let r = 0;
    while (r < len(rows)) {
        let row = rows[r];
        let f = 0;
        while (f < len(row)) {
            if (f > 0) { out += chr(delim); };
            out += csv_quote(row[f], delim, always);
            f = f + 1;
        };
        out += eol;
        r = r + 1;
    };
    out
};

// ── number recognition ────────────────────────────────────────────────────

def isdig(c: long) -> bool { c >= 48 && c <= 57 };

// num_token(s: str) -> bool -- is s EXACTLY a JSON number token? Used by
// --num to decide whether a CSV field is a number or a string. Written out
// against the JSON grammar because Y has no regex and no float -> long
// conversion to lean on, and because "007" and "1,5" and "" must NOT
// count.
def num_token(s: str) -> bool {
    let n = len(s);
    let i = 0;
    let ok = n > 0;
    if (ok && byte_at(s, 0) == 45) { i = 1; ok = n > 1; };
    if (ok) {
        // int part: 0, or [1-9][0-9]*
        if (byte_at(s, i) == 48) {
            i = i + 1;
        } else if (byte_at(s, i) >= 49 && byte_at(s, i) <= 57) {
            let go = true;
            while (go) { if (i < n && isdig(byte_at(s, i))) { i = i + 1; } else { go = false; }; }
        } else {
            ok = false;
        };
        // frac part: '.' then at least one digit
        if (ok && i < n && byte_at(s, i) == 46) {
            i = i + 1;
            if (i >= n) {
                ok = false;
            } else {
                let go = true;
                while (go) { if (i < n && isdig(byte_at(s, i))) { i = i + 1; } else { go = false; }; }
            };
        };
        // exp part: [eE][+-]?[0-9]+
        if (ok && i < n && (byte_at(s, i) == 101 || byte_at(s, i) == 69)) {
            i = i + 1;
            if (i < n && (byte_at(s, i) == 43 || byte_at(s, i) == 45)) { i = i + 1; };
            if (i >= n) {
                ok = false;
            } else {
                let go = true;
                while (go) { if (i < n && isdig(byte_at(s, i))) { i = i + 1; } else { go = false; }; }
            };
        };
        if (i != n) { ok = false; };
    };
    ok
}

// ── CSV -> JSON ───────────────────────────────────────────────────────────
//
// csv_to_json(rows: [[str]], header: bool, numbers: bool) -> JVal?
//
// With --header the first record names the keys and every later record
// becomes an object; without it the document is an array of arrays and
// every field is a JSON string, which is what CSV actually is. --num makes
// a field that is exactly a JSON number become one and leaves every other
// field a string.
def csv_to_json(rows: [[str]], header: bool, numbers: bool) -> JVal? {
    csv_err = "";
    let out = jsonval.j_arr();
    let r0 = 0;
    let names: [str] = [];
    let ncol = 0;
    if (header) {
        if (len(rows) == 0) {
            csv_err = "--header needs at least one record to name the columns";
            return none
        };
        ncol = len(rows[0]);
        names = rows[0];
        // A duplicate name would make one column unreachable in the object,
        // so it is refused rather than silently dropped.
        let a = 0;
        while (a < ncol && csv_err == "") {
            let b = a + 1;
            while (b < ncol) {
                if (names[a] == names[b]) {
                    csv_err = "the header has the name " + jsonval.p_quote(names[a]) +
                              " twice (columns " + tostring(a + 1) + " and " + tostring(b + 1) + ")";
                };
                b = b + 1;
            };
            a = a + 1
        };
        r0 = 1
    };
    let r = r0;
    let go = r < len(rows) && csv_err == "";
    while (go) {
        let row = rows[r];
        let item = jsonval.j_arr();
        if (header) {
            if (len(row) != ncol) {
                csv_err = "record " + tostring(r + 1) + " has " + tostring(len(row)) +
                          " field(s) but the header has " + tostring(ncol);
            } else {
                item = jsonval.j_obj();
                let c = 0;
                while (c < ncol) { item.fields += { k: names[c], v: field_json(row[c], numbers) }; c = c + 1 }
            };
        } else {
            let c = 0;
            while (c < len(row)) { item.items += field_json(row[c], numbers); c = c + 1 }
        };
        if (csv_err == "") { out.items += item; };
        r = r + 1;
        go = r < len(rows) && csv_err == ""
    };
    if (csv_err != "") { none } else { some(out) }
};

// field_json(s: str, numbers: bool) -> JVal -- one CSV field.
def field_json(s: str, numbers: bool) -> JVal {
    let v = jsonval.j_str(s);
    if (numbers && num_token(s)) {
        let iv = 0;
        if (s.index_of(".") < 0 && s.index_of("e") < 0 && s.index_of("E") < 0 && len(s) <= 18) {
            iv = tolong(s)!
        };
        v = jsonval.j_num(s, iv)
    };
    v
}

// ── JSON -> CSV ───────────────────────────────────────────────────────────
//
// json_to_csv(doc: JVal, header: bool) -> [[str]]
//
// The document must be an array. With --header each element must be an
// object -- its keys give the column names, in their own order, which is
// insertion order, so the output is stable -- and without it each element
// must be an array. A container nested inside a field is an error rather
// than a silently JSON-encoded blob, because CSV has one dimension.
def json_to_csv(doc: JVal, header: bool) -> [[str]] {
    csv_err = "";
    let rows: [[str]] = [];
    if (doc.kind != 4) {
        csv_err = "--op=from-json wants a top-level array of records, not " +
                  jsonval.kind_name(doc.kind);
        return rows
    };
    let names: [str] = [];
    let ncol = 0;
    let r0 = 0;
    // With --header the FIRST record names the columns, and it may be an
    // object (its keys are the names) or an array (its values are). That
    // matters because a CSV -> JSON -> CSV round trip arrives here as an
    // array of arrays, and refusing it would make the round trip
    // impossible to express.
    let hdr_obj = false;
    if (header) {
        if (len(doc.items) == 0) {
            csv_err = "--header needs at least one record to name the columns";
            return rows
        };
        let h = doc.items[0];
        if (h.kind == 5) {
            hdr_obj = true;
            ncol = len(h.fields);
            let c = 0;
            while (c < ncol) { names += h.fields[c].k; c = c + 1; };
        } else if (h.kind == 4) {
            ncol = len(h.items);
            let c = 0;
            while (c < ncol) { names += field_text(h.items[c], 0, c); c = c + 1; };
        } else {
            csv_err = "record 1 is the header, so it must be an object or an array, not " +
                      jsonval.kind_name(h.kind);
            return rows
        };
        if (csv_err != "") { return rows };
        rows += names;
        r0 = 1
    };
    let r = r0;
    let go = r < len(doc.items);
    while (go) {
        let it = doc.items[r];
        let row: [str] = [];
        if (header && hdr_obj) {
            if (it.kind != 5) {
                csv_err = "record " + tostring(r + 1) + " must be an object, not " +
                          jsonval.kind_name(it.kind);
            } else if (len(it.fields) != ncol) {
                csv_err = "record " + tostring(r + 1) + " has " + tostring(len(it.fields)) +
                          " key(s) but the header has " + tostring(ncol);
            } else {
                let c = 0;
                while (c < ncol && csv_err == "") { row += field_text(it.fields[c].v, r, c); c = c + 1 }
            };
        } else {
            if (it.kind != 4) {
                csv_err = "record " + tostring(r + 1) + " must be an array of fields, not " +
                          jsonval.kind_name(it.kind);
            } else {
                let c = 0;
                while (c < len(it.items) && csv_err == "") { row += field_text(it.items[c], r, c); c = c + 1 }
            };
        };
        if (csv_err == "") { rows += row };
        r = r + 1;
        go = r < len(doc.items) && csv_err == ""
    };
    rows
};

// field_text(v: JVal, r: long, c: long) -> str -- a JSON scalar as CSV
// text. null becomes the empty string because CSV has no null; a number
// becomes its exact token, never tostring of a float.
def field_text(v: JVal, r: long, c: long) -> str {
    let s = "";
    if (v.kind == 0) {
        s = "";
    } else if (v.kind == 4 || v.kind == 5) {
        csv_err = "record " + tostring(r + 1) + " field " + tostring(c + 1) + " is " +
                  jsonval.kind_name(v.kind) + "; CSV has one dimension, so it needs a column of its own";
    } else {
        s = jsonval.scalar_text(v)
    };
    s
};

export { csv_delim, csv_delim_name, csv_parse, csv_err, csv_quote, csv_render, csv_to_json, json_to_csv, field_json, num_token, crlf_step };