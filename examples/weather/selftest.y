// selftest.y -- the property checks. `weather --check` runs this.
//
// A golden file proves determinism, not rightness. examples/cube cleared all
// eight gate items while rendering faces as axis-aligned rectangles,
// because its EXPECTED was generated from the broken output. So every claim
// here is asserted against something other than a recorded answer, and
// each section names the defect it would catch.
//
//   A  round-trip identity    the bytes the service emits parse to exactly
//                             the values the service meant, field by field,
//                             and re-emitting and re-parsing is a fixed
//                             point. Catches: a wire format that does not
//                             say what the data says; a parser that
//                             silently drops or reorders members.
//   B  error paths are real   404 for an unknown slug, 400 for a malformed
//                             query, both over the wire, both surfacing a
//                             status and a message, non-zero exit, and NO
//                             partially-filled report. Catches: a renderer
//                             that paints what it has before checking.
//   C  integer unit maths     exact expected integers for known Celsius
//                             values, including -40 where the scales
//                             coincide, and the rounding cases where a
//                             truncating converter is one degree out.
//                             Catches: a wrong constant, a truncation, a
//                             sign slip, a float creeping in.
//   D  malformed JSON         fourteen broken documents, each rejected with
//                             a message and no trap. Catches: a parser that
//                             accepts half a document, and any path that
//                             would trap (traps print to STDOUT, so one
//                             would corrupt EXPECTED instead of failing).
//   E  framing                Content-Length equals the byte count the
//                             client received, for both a length-framed
//                             and a chunk-framed reply. Catches: a header
//                             computed from something other than the body.
//
// Exit 0 when every check passed, 1 otherwise. Both the pass and the fail
// paths print to stdout and neither traps.

import http;
import net;
import json;
import wxfmt;
import wxdata;
import wxsrv;
import wxrep;

const TAG = "wx.v1";

type Count = { pass: long, fail: long };

def verdict(c: Count, ok: bool, name: str, detail: str = "") -> Count {
    if (ok) {
        print("  ok    " + name);
        { pass: c.pass + 1, fail: c.fail }
    } else {
        print("  FAIL  " + name + (detail.length > 0 ? "  [" + detail + "]" : ""));
        { pass: c.pass, fail: c.fail + 1 }
    }
};

def eq(got: long, want: long) -> bool { got == want };

// ── A. round-trip identity ─────────────────────────────────────────────

def roundtrip(c: Count, verbose: bool) -> Count {
    print("A. round-trip identity: emitted bytes parse to the intended values");
    let ps = wxdata.places();
    let i = 0;
    while (i < ps.length) {
        let p = ps[i];
        let wire = json.emit(wxdata.forecast_tree(p));
        let d = json.parse(wire);
        c = verdict(c, d.ok, p.slug + ": the document parses", d.err);
        if (d.ok) {
            let loc = json.obj(d.val, "location");
            let cur = json.obj(d.val, "current");
            c = verdict(c, json.str_of(d.val, "schema") == TAG, p.slug + ": schema");
            c = verdict(c, json.str_of(loc, "name") == p.name, p.slug + ": location.name");
            c = verdict(c, json.str_of(loc, "region") == p.region, p.slug + ": location.region");
            c = verdict(c, json.str_of(loc, "country") == p.country, p.slug + ": location.country");
            c = verdict(c, json.int_of(loc, "lat") == p.lat, p.slug + ": location.lat",
                        "got " + tostring(json.int_of(loc, "lat")) + " want " + tostring(p.lat));
            c = verdict(c, json.int_of(loc, "lon") == p.lon, p.slug + ": location.lon");
            c = verdict(c, json.str_of(loc, "tz") == p.tz, p.slug + ": location.tz");
            c = verdict(c, json.str_of(cur, "time") == p.current.time, p.slug + ": current.time");
            c = verdict(c, json.int_of(cur, "code") == p.current.code, p.slug + ": current.code");
            c = verdict(c, json.int_of(cur, "temp_c") == p.current.temp_c, p.slug + ": current.temp_c");
            c = verdict(c, json.int_of(cur, "feels_like_c") == p.current.feels_like_c,
                        p.slug + ": current.feels_like_c");
            c = verdict(c, json.int_of(cur, "wind_kmph") == p.current.wind_kmph, p.slug + ": current.wind_kmph");
            c = verdict(c, json.int_of(cur, "humidity") == p.current.humidity, p.slug + ": current.humidity");
            c = verdict(c, json.int_of(cur, "pressure_hpa") == p.current.pressure_hpa,
                        p.slug + ": current.pressure_hpa");
            let rows = json.arr_of(d.val, "daily");
            c = verdict(c, rows.length == p.days.length, p.slug + ": daily has "
                        + tostring(p.days.length) + " rows", "got " + tostring(rows.length));
            let j = 0;
            while (j < rows.length && j < p.days.length) {
                let r = rows[j];
                let w = p.days[j];
                let tag = p.slug + " day " + tostring(j);
                c = verdict(c, json.str_of(r, "date") == w.date, tag + ": date");
                c = verdict(c, json.int_of(r, "code") == w.code, tag + ": code");
                c = verdict(c, json.int_of(r, "min_c") == w.min_c, tag + ": min_c");
                c = verdict(c, json.int_of(r, "max_c") == w.max_c, tag + ": max_c");
                c = verdict(c, json.int_of(r, "precip_mm") == w.precip_mm, tag + ": precip_mm");
                c = verdict(c, json.int_of(r, "wind_kmph") == w.wind_kmph, tag + ": wind_kmph");
                j = j + 1;
            };
            // Fixed point: emit the tree the parser built and it must come
            // back byte for byte, and a second parse must agree again.
            let again = json.emit(d.val);
            c = verdict(c, again == wire, p.slug + ": re-emitting the parsed tree is byte-identical");
            let d2 = json.parse(again);
            c = verdict(c, d2.ok && json.emit(d2.val) == again, p.slug + ": re-parsing is stable");
            if (verbose) {
                print("        " + tostring(len(wire)) + " bytes, " + tostring(rows.length) + " days");
            };
        };
        i = i + 1;
    };
    // The same for the location list, which is served chunk-framed.
    let lt = wxdata.locations_tree(ps);
    let lwire = json.emit(lt);
    let ld = json.parse(lwire);
    c = verdict(c, ld.ok, "locations: the document parses", ld.err);
    c = verdict(c, json.arr_of(ld.val, "locations").length == ps.length,
                "locations: every place is listed");
    c = verdict(c, json.emit(ld.val) == lwire, "locations: re-emitting is byte-identical");

    // The wire format is INTEGERS all the way down, and that is a property,
    // not a style choice: json keeps only the text of a number that has a
    // fraction or an exponent, so a document carrying -0.22985 as a
    // latitude reads back as 0 and a report prints 0.00000. Every number in
    // every document this service emits must be a plain integer literal.
    let k = 0;
    while (k < ps.length) {
        c = verdict(c, whole_numbers(json.parse(json.emit(wxdata.forecast_tree(ps[k]))).val, ""),
                    ps[k].slug + ": every number in the document is an integer literal");
        k = k + 1;
    };
    c = verdict(c, whole_numbers(json.parse(lwire).val, ""),
                "locations: every number in the document is an integer literal");
    // A negative control: the predicate must be able to say NO, or the two
    // checks above prove nothing. These are the exact shapes that would make
    // a report print 0.00000 for a real coordinate.
    c = verdict(c, !whole_numbers(json.parse("{\"lat\":-0.22985}").val, ""),
                "a fractional literal is NOT an integer literal");
    c = verdict(c, !whole_numbers(json.parse("{\"lat\":3.0e2}").val, ""),
                "an exponent is NOT an integer literal");
    c = verdict(c, !whole_numbers(json.parse("{\"a\":[1,{\"b\":2.5}]}").val, ""),
                "a fraction nested in an array is caught too");
    c = verdict(c, whole_numbers(json.parse("{\"a\":1,\"b\":-2,\"c\":{\"d\":[3]}}").val, ""),
                "nested integers are accepted");
    c = verdict(c, whole_numbers(json.parse("{\"a\":\"2.5\"}").val, ""),
                "a fraction inside a STRING is not a number and is not the parser's business");
    c
};

// Every "num" node in the tree has an integer literal: no '.', no 'e', no
// 'E', and a leading '-' at most. `why` travels with the complaint.
def whole_numbers(v: json.Json, why: str) -> bool {
    if (v.kind == "obj") {
        let ok = true;
        let i = 0;
        while (i < v.keys.length) {
            if (!whole_numbers(v.vals[i], why + "." + v.keys[i])) { ok = false };
            i = i + 1;
        };
        ok
    } else if (v.kind == "arr") {
        let ok = true;
        let i = 0;
        while (i < v.items.length) {
            if (!whole_numbers(v.items[i], why + "[" + tostring(i) + "]")) { ok = false };
            i = i + 1;
        };
        ok
    } else if (v.kind == "num") {
        let t = v.s;
        let ok = t.length > 0;
        let i = 0;
        while (i < t.length) {
            let c = ord(t[i:i + 1]);
            if (c < 48 || c > 57) {
                if (i == 0 && c == 45) { } else { ok = false };
            };
            i = i + 1;
        };
        ok
    } else { true }
};

// ── B and E. the error paths and the framing, over a real socket ───────

// Answers one request against the local service and returns what the client
// saw. `text()` is called exactly once, and the result is what is compared:
// a second read would silently give "" (examples/BUGS.md).
type Seen = { status: long, reason: str, body: str, clen: long, chunked: bool, err: str };

def ask(port: long, target: str) -> Seen {
    let o: http.Opts = { timeout: 10 };
    let r = http.get("http://127.0.0.1:" + tostring(port) + target, o);
    if (r.status == 0) {
        { status: 0, reason: "", body: "", clen: 0 - 1, chunked: false, err: r.err }
    } else {
        let body = r.text();
        // A header lookup on a map is an option: a header the peer did not
        // send is `none`, and asking it for .length would be reading a field
        // off something that is not there.
        let te = header(r, "transfer-encoding");
        let cl = header(r, "content-length");
        { status: r.status, reason: r.reason, body: body,
          clen: cl.length > 0 ? tolong(cl) : 0 - 1,
          chunked: te == "chunked", err: r.err }
    }
};

// A header value, or "" when the response did not carry one. Names are
// already lower-cased by std/http.
def header(r: http.Response, name: str) -> str {
    let v = r.headers[name];
    if (is_some(v)) { unwrap(v) } else { "" }
};

def errpaths(c: Count, port: long, verbose: bool) -> Count {
    print("B. error paths are real: 404, 400, and no partially-filled report");
    let bad = ask(port, "/v1/forecast?city=n");
    c = verdict(c, bad.status == 404, "unknown slug is 404", "got " + tostring(bad.status));
    c = verdict(c, bad.body.length > 0, "the 404 carries a body");
    let d404 = json.parse(bad.body);
    c = verdict(c, d404.ok && json.str_of(json.obj(d404.val, "error"), "code") == "not_found",
                "the 404 body says not_found", d404.err);
    c = verdict(c, json.has(d404.val, "location") == false,
                "the 404 body has no location section: nothing to render");

    let b1 = ask(port, "/v1/forecast?city=reyk%20javik");
    c = verdict(c, b1.status == 400, "a slug with a space is 400", "got " + tostring(b1.status));
    c = verdict(c, json.parse(b1.body).ok
                && json.str_of(json.obj(json.parse(b1.body).val, "error"), "code") == "bad_query",
                "the 400 body says bad_query");
    let b2 = ask(port, "/v1/forecast?city=Reykjavik");
    c = verdict(c, b2.status == 400, "an upper-case slug is 400 (the grammar is lower-case only)",
                "got " + tostring(b2.status));
    let b3 = ask(port, "/v1/forecast?city=");
    c = verdict(c, b3.status == 400, "an empty slug is 400", "got " + tostring(b3.status));
    let b4 = ask(port, "/v1/forecast");
    c = verdict(c, b4.status == 400, "a missing city parameter is 400", "got " + tostring(b4.status));
    let b5 = ask(port, "/v1/nothing-here");
    c = verdict(c, b5.status == 404, "an unknown resource is 404", "got " + tostring(b5.status));
    c = verdict(c, b5.status != b1.status, "unknown slug and unknown resource agree; "
                + "malformed slug and unknown slug do not");

    // A 200 whose body is not a document. This is the one that catches a
    // renderer that draws before it checks: the client must refuse it, and
    // the refusal must be total.
    let br = ask(port, "/v1/broken");
    c = verdict(c, br.status == 200, "the truncated document is served as 200");
    c = verdict(c, json.parse(br.body).ok == false, "the truncated body does not parse",
                json.parse(br.body).err);
    let refused = refuse(br);
    c = verdict(c, refused.ok == false, "the client refuses a 200 that will not parse");
    c = verdict(c, refused.msg.length > 0, "the refusal carries a message", refused.msg);
    c = verdict(c, report_of(br).length == 0, "a refused document renders nothing at all",
                "the report was " + tostring(report_of(br).length) + " bytes");

    // The interesting half of the same property. This body PARSES -- the
    // parser cannot catch it -- and it is still not this service's document,
    // so the refusal has to be the client's own. Removing the schema check
    // from `refuse` makes this line fail, which is how it is known to be
    // more than a restatement of the line above.
    let wrong = ask(port, "/v1/wrong-schema");
    c = verdict(c, wrong.status == 200, "the wrong-schema document is served as 200");
    let wd = json.parse(wrong.body);
    c = verdict(c, wd.ok, "and it PARSES: the parser cannot be what refuses it", wd.err);
    c = verdict(c, json.str_of(wd.val, "schema") != TAG, "its schema really is not " + TAG);
    c = verdict(c, json.has(wd.val, "location") && json.has(wd.val, "current")
                && json.has(wd.val, "daily"),
                "and it even has every section the renderer wants");
    c = verdict(c, refuse(wrong).ok == false, "the client refuses a parsed document that is not ours");
    c = verdict(c, refuse(wrong).msg.length > 0, "with a message", refuse(wrong).msg);
    let painted = 0;
    if (wd.ok) { painted = wxrep.render(wd.val, 4).length };
    c = verdict(c, painted > 0, "a renderer WOULD have painted it, so the refusal is load-bearing",
                "the renderer produced " + tostring(painted) + " bytes");
    c = verdict(c, report_of(wrong).length == 0, "and the client prints none of it",
                "the report was " + tostring(report_of(wrong).length) + " bytes");
    // And the refusal is not a blanket one: a real document is accepted.
    c = verdict(c, refuse(ask(port, "/v1/forecast?city=quito")).ok,
                "a real wx.v1 document is NOT refused");
    c = verdict(c, report_of(ask(port, "/v1/forecast?city=quito")).length > 0,
                "and it does render");

    // And the whole client entry point, exit codes and all. The child runs
    // with both streams redirected, so a check's own output cannot be
    // polluted by a report, and only the exit status is looked at.
    c = verdict(c, prog("--city nowhere") == 1, "--city nowhere exits 1");
    c = verdict(c, prog("--city 'reyk javik'") == 1, "--city 'reyk javik' exits 1");
    c = verdict(c, prog("--city ''") == 2, "--city '' is a usage error (exit 2)");
    c = verdict(c, prog("--city Reykjavik") == 0, "--city Reykjavik exits 0 (the CLI folds case)");
    c = verdict(c, prog("--city quito") == 0, "--city quito exits 0");
    c = verdict(c, prog("--list") == 0, "--list exits 0");
    c = verdict(c, prog("--city quito --days 2") == 0, "--city quito --days 2 exits 0");
    c = verdict(c, prog("--days 9") == 2, "--days 9 is a usage error (exit 2)");
    c = verdict(c, prog("--days abc") == 2, "--days abc is a usage error (exit 2)");
    c = verdict(c, prog("--nonsense") == 2, "an unknown flag is a usage error (exit 2)");
    c = verdict(c, prog("--live") == 2, "--live without --city is a usage error (exit 2)");
    c = verdict(c, prog("--help") == 0, "--help exits 0");

    print("E. framing: Content-Length equals the bytes the client received");
    let len = ask(port, "/v1/forecast?city=quito");
    c = verdict(c, len.status == 200, "the forecast is 200");
    c = verdict(c, len.clen == len.body.length, "Content-Length equals the body byte count",
                "header " + tostring(len.clen) + " body " + tostring(len.body.length));
    let chunk = ask(port, "/v1/locations");
    c = verdict(c, chunk.status == 200, "the location list is 200");
    c = verdict(c, chunk.chunked, "the location list really is chunk-framed");
    c = verdict(c, chunk.clen == 0 - 1, "a chunked reply carries no Content-Length",
                "got " + tostring(chunk.clen));
    c = verdict(c, json.parse(chunk.body).ok, "the chunked body reassembles into JSON");
    let head = wxsrv.response_text(wxsrv.route("GET /v1/forecast?city=quito HTTP/1.1\r\n\r\n"));
    let claimed = 0;
    let mark = index_of(head, "Content-Length: ");
    if (mark >= 0) { claimed = tolong(claim_after(head, mark + 16)) };
    c = verdict(c, claimed == wxsrv.route("GET /v1/forecast?city=quito HTTP/1.1\r\n\r\n").body.length,
                "the declared length is the length of the body beside it",
                "header " + tostring(claimed));
    if (verbose) {
        print("        length-framed " + tostring(len.clen) + " B, chunk-framed "
              + tostring(chunk.body.length) + " B");
    };
    c
};

// The digits after the Content-Length header value, up to the CR.
// The `;` sits inside the braces on purpose: a value-used append (json.y's
// esc() explains the rule) copies the whole string built so far, and this
// appends one digit per character.
def claim_after(s: str, from: long) -> str {
    let out = "";
    let i = from;
    while (i < s.length) {
        let c = ord(s[i:i + 1]);
        if (c >= 48 && c <= 57) { out += chr(c); } else { i = s.length };
        i = i + 1;
    };
    out
};

// The client's own refusal, with no side effects: this is exactly what
// weather.y's need() does after a fetch, minus the printing.
//
// The last value is ok:true on purpose. Returning a default `{ok:false}` at
// the end would make every path "refuse", so dropping any single check would
// still look like a refusal -- and the assertions below would stop meaning
// anything. Refusing has to be something this function can fail to do.
type Refused = { ok: bool, msg: str };

def refuse(s: Seen) -> Refused {
    if (s.status == 0) { return { ok: false, msg: "no response from the service: " + s.err } };
    if (s.status != 200) {
        let d = json.parse(s.body);
        if (d.ok && json.has(d.val, "error")) {
            return { ok: false, msg: "HTTP " + tostring(s.status) + " " + s.reason + ": "
                   + json.str_of(json.obj(d.val, "error"), "message") };
        };
        return { ok: false, msg: "HTTP " + tostring(s.status) + " " + s.reason };
    };
    let d = json.parse(s.body);
    if (!d.ok) {
        return { ok: false, msg: "the body is not JSON at byte " + tostring(d.at) + ": " + d.err };
    };
    if (json.str_of(d.val, "schema") != TAG) {
        return { ok: false, msg: "expected schema " + TAG + ", got \""
               + json.str_of(d.val, "schema") + "\"" };
    };
    if (!json.has(d.val, "location") || !json.has(d.val, "current") || !json.has(d.val, "daily")) {
        return { ok: false, msg: "the document has no location, current or daily section" };
    };
    { ok: true, msg: "" }
};

// What the renderer would have produced for this response. Empty for
// anything the client refuses, which is the property: no partial report.
def report_of(s: Seen) -> str {
    let r = refuse(s);
    if (!r.ok) { return "" };
    wxrep.render(json.parse(s.body).val, 4)
};

// Run this program again as a child, with both streams redirected, and hand
// back its exit status. That is the only honest way to assert an exit code:
// this process is the program, so a call would be a recursive check.
def prog(rest: str) -> long {
    exec("./weather " + rest + " >/dev/null 2>&1")
};

// ── C. the integer unit conversions ────────────────────────────────────

// name, Celsius in, Fahrenheit out. Every entry is a hand-computed
// expectation, not a re-run of the code under test.
type Conv = { c: long, f: long, why: str };

const CONVS: [Conv] = [
    { c: 0, f: 32, why: "the freezing point of water, the number everyone checks" },
    { c: 100, f: 212, why: "the boiling point, the other one" },
    { c: -40, f: -40, why: "the boundary: the two scales coincide exactly here" },
    { c: 37, f: 99, why: "98.6 F exactly; truncation would say 98" },
    { c: -37, f: -35, why: "-34.6 F; truncation toward zero would say -34" },
    { c: 22, f: 72, why: "room temperature" },
    { c: -18, f: 0, why: "-0.4 F rounds to zero, not to -0" },
    { c: -30, f: -22, why: "an exact negative conversion" },
    { c: 8, f: 46, why: "46.4 F" },
    { c: -1, f: 30, why: "30.2 F" },
    { c: 1, f: 34, why: "33.8 F" },
    { c: -3, f: 27, why: "reykjavik's current temperature, so the report shows it" }
];

const MPHS: [Conv] = [
    { c: 0, f: 0, why: "calm" },
    { c: 24, f: 149, why: "reykjavik's wind: 14.9 mph in tenths" },
    { c: 41, f: 255, why: "longyearbyen's wind: 25.5 mph in tenths" },
    { c: 100, f: 621, why: "62.1 mph in tenths" },
    { c: 1609, f: 9998, why: "999.8 mph in tenths: a near-1000 mph figure that must not drift" }
];

def conv(c: Count) -> Count {
    print("C. integer unit conversion: exact expected values, no float involved");
    let i = 0;
    while (i < CONVS.length) {
        let t = CONVS[i];
        let got = wxfmt.c_to_f(t.c);
        c = verdict(c, got == t.f, "C " + wxfmt.deg_c(t.c) + " = " + wxfmt.deg_f(t.f)
                    + "  (" + t.why + ")", "got " + wxfmt.deg_f(got));
        i = i + 1;
    };
    // The one that needs stating separately: -40 is the only temperature
    // where the two scales agree, so a converter that is right everywhere
    // else and wrong there has a constant off by a rounding.
    c = verdict(c, wxfmt.c_to_f(0 - 40) == 0 - 40, "-40 C is -40 F exactly");
    c = verdict(c, wxfmt.c_to_f(0 - 40 + 1) != 0 - 40 + 1, "-39 C is not -39 F");
    // Round-half-away-from-zero, and exact division must not creep up.
    c = verdict(c, wxfmt.round_div(0 - 7, 2) == 0 - 4, "round_div(-7, 2) = -4 (ties away from zero)");
    c = verdict(c, wxfmt.round_div(7, 2) == 4, "round_div(7, 2) = 4");
    c = verdict(c, wxfmt.round_div(6, 2) == 3, "round_div(6, 2) = 3 (exact division does not creep)");
    c = verdict(c, wxfmt.round_div(0 - 6, 2) == 0 - 3, "round_div(-6, 2) = -3");
    c = verdict(c, wxfmt.round_div(5, 10) == 1, "round_div(5, 10) = 1 (a tie rounds up)");
    c = verdict(c, wxfmt.round_div(0 - 5, 10) == 0 - 1, "round_div(-5, 10) = -1");
    let j = 0;
    while (j < MPHS.length) {
        let t = MPHS[j];
        let got = wxfmt.kmh_to_mph10(t.c);
        c = verdict(c, got == t.f, wxfmt.mph1(t.c) + " mph from " + tostring(t.c) + " km/h"
                    + "  (" + t.why + ")", "got " + tostring(got));
        j = j + 1;
    };
    // The converter is monotonic and it never decreases: a converter that
    // folded on a negative input would pass the table above.
    let mono = true;
    let m = 0 - 60;
    while (m < 60) {
        if (wxfmt.c_to_f(m) >= wxfmt.c_to_f(m + 1)) { mono = false };
        m = m + 1;
    };
    c = verdict(c, mono, "C -> F is strictly increasing over -60 C to 60 C");
    c = verdict(c, wxfmt.c_to_f(0 - 40) - wxfmt.c_to_f(0) == 0 - 72,
                "the -40 C step is exactly -72 F, the width of the scales");
    c
};

// ── D. malformed JSON ──────────────────────────────────────────────────

type Bad = { text: str, why: str };

const BADS: [Bad] = [
    { text: "{\"schema\":\"wx.v1\",\"location\":{\"name\":\"Nowhere\",", why: "a truncated object" },
    { text: "{\"a\":1,\"b\":2,}", why: "a trailing comma in an object" },
    { text: "{a:1}", why: "an unquoted key" },
    { text: "{'a':1}", why: "single quotes" },
    { text: "{\"a\":\"\\q\"}", why: "an unknown escape" },
    { text: "{\"a\":\"\\u12\"}", why: "a \\u with too few hex digits" },
    { text: "[1,2,3", why: "an unbalanced bracket" },
    { text: "", why: "an empty body" },
    { text: "   ", why: "whitespace only" },
    { text: "{\"a\" 1}", why: "a missing colon" },
    { text: "{\"a\":1}}", why: "trailing bytes after the document" },
    { text: "{\"a\":1,\"a\":2}", why: "a duplicate key" },
    { text: "[1,]", why: "a trailing comma in an array" },
    { text: "01", why: "a leading zero" },
    { text: "{\"a\":+1}", why: "a leading plus" },
    { text: "{\"a\":1,}", why: "a trailing comma before the brace" },
    { text: "{\"a\":\"\\uD800\"}", why: "a lone high surrogate" },
    { text: "nul", why: "a truncated literal" },
    { text: "{\"a\":1.}", why: "a fraction with no digits" }
];

def bad(c: Count, verbose: bool) -> Count {
    print("D. the parser rejects malformed JSON, with a message and no trap");
    let i = 0;
    while (i < BADS.length) {
        let b = BADS[i];
        let d = json.parse(b.text);
        c = verdict(c, d.ok == false, "rejects " + b.why);
        c = verdict(c, d.err.length > 0, "  ...with a message for " + b.why, d.err);
        c = verdict(c, d.at >= 0 && d.at <= b.text.length, "  ...and a byte offset for " + b.why,
                    "at " + tostring(d.at));
        // A refused parse must still be a total value: the tree is a null
        // node, so a caller that forgets to look gets zeros, never a trap.
        c = verdict(c, json.int_of(d.val, "location") == 0, "  ...and the tree is safe to read");
        if (verbose) { print("        " + d.err + " (byte " + tostring(d.at) + ")") };
        i = i + 1;
    };
    // Deep nesting is a guard, not a crash: the limit answers with a message.
    // 32 levels is the last that fits (the innermost `[]` never recurses,
    // because an empty array is closed by the parser itself), and 34 is the
    // first that does not.
    let deep = deep_doc(34);
    let dd = json.parse(deep);
    c = verdict(c, dd.ok == false, "rejects nesting past the depth limit", dd.err);
    c = verdict(c, dd.err.length > 0, "  ...with a message for over-deep nesting");
    c = verdict(c, json.parse(deep_doc(32)).ok, "32 levels of nesting is accepted");
    c = verdict(c, json.parse(deep_doc(33)).ok, "33 levels of nesting is accepted");
    c = verdict(c, json.parse(deep_doc(8)).ok, "8 levels of nesting is accepted");

    // A parser that rejects everything would pass every line above, so the
    // other half of the property: documents that ARE valid, including the
    // number shapes that are easy to get wrong (a bare 0, a negative zero, a
    // fraction, an exponent, and a literal that must keep its text because
    // there is no float -> long conversion).
    let goods: [str] = [
        "0", "-0", "1", "-1", "0.5", "-1.5", "3.25e2", "2E-3", "12345678901",
        "{}", "[]", "[1,2,3]", "{\"a\":{}}", "{\"a\":[]}", "\"\"",
        "true", "false", "null", "{\"a\":null,\"b\":true,\"c\":false}",
        "\"\\u00e9\"", "\"\\n\\t\\\\\"", "\"\\ud83d\\ude00\""
    ];
    let g = 0;
    while (g < goods.length) {
        c = verdict(c, json.parse(goods[g]).ok, "accepts " + goods[g],
                    json.parse(goods[g]).err);
        g = g + 1;
    };
    c = verdict(c, json.int_of(json.parse("0").val, "a", 0) == 0, "0 is a number, not a rejection");
    c = verdict(c, json.parse("0").ok, "a bare 0 is valid JSON");
    c = verdict(c, json.parse("12345678901").ok && json.parse("12345678901").val.n == 12345678901,
                "an 11-digit integer is exact");
    c = verdict(c, json.parse("3.25e2").val.s == "3.25e2",
                "a number with an exponent keeps its literal text");
    c = verdict(c, json.emit(json.parse("3.25e2").val) == "3.25e2",
                "and re-emits it unchanged");
    c = verdict(c, json.text(json.parse("\"\\ud83d\\ude00\"").val) == "\xf0\x9f\x98\x80",
                "a surrogate pair becomes the four UTF-8 bytes it stands for");
    // \xHH is the only byte escape: "\360" is formfeed followed by 360,
    // because unescape reads \f as a formfeed and leaves the digits as text.
    c = verdict(c, "\xf0\x9f\x98\x80".length == 4, "\\xHH makes one byte, four times");
    c = verdict(c, "\xc2\xb0".length == 2, "\\xHH makes the two bytes of a degree sign");
    c = verdict(c, wxfmt.glyph(0).length == 3, "the clear-sky glyph is three bytes, one cell",
                "got " + tostring(wxfmt.glyph(0).length));
    c = verdict(c, wxfmt.dwidth(wxfmt.glyph(0)) == 1, "and one cell wide");
    c = verdict(c, wxfmt.dwidth("ab" + wxfmt.glyph(71)) == 3,
                "dwidth counts codepoints, not bytes");
    c = verdict(c, wxfmt.rpad(wxfmt.glyph(71), 3).length == 5,
                "and rpad pads by cells: three bytes plus two spaces", "got "
                + tostring(wxfmt.rpad(wxfmt.glyph(71), 3).length));
    c = verdict(c, wxfmt.deg_c(37).length == 6, "37 degrees Celsius is six bytes (the degree sign is two)",
                "got " + tostring(wxfmt.deg_c(37).length));
    c
};

def deep_doc(depth: long) -> str {
    let s = "";
    let i = 0;
    while (i < depth) { s += "["; i = i + 1 };
    i = 0;
    while (i < depth) { s += "]"; i = i + 1 };
    s
};

// ── F. the escaper's cost is linear in its input ──────────────────────
//
// The defect this section exists for. `json.esc()` appended with `+=` as the
// LAST statement of each braced arm, which is a *value-used* position, so the
// compiler emitted `out = out + x` -- a fresh exact-size buffer per character
// (examples/BUGS.md, "`str +=` in a value-used position makes its whole loop
// O(n^2) in heap"). The output was byte-identical and the cost was invisible
// until the input grew: measured against this program's own json.y, escaping
// n plain characters allocated
//
//     n=  200     42 032 B
//     n=  400    124 032 B     2.95x
//     n=  800    408 032 B     3.29x
//     n= 1600  1 456 032 B     3.57x      (4x per doubling, i.e. quadratic)
//
// and 1.4 MB for one 1600-character string is a payload that meets the 3.5 GiB
// cap and reports "out of memory" with nothing pointing at the cause. The fix
// is one character per arm -- the `;` goes INSIDE the braces, because `;` after
// the closing brace discards the if-statement's value and leaves the arm's own
// last statement value-used -- and the same measurement after it:
//
//     n=  200     17 136 B
//     n=  400     34 128 B     1.99x
//     n=  800     68 088 B     1.99x
//     n= 1600    135 984 B     2.00x      (2x per doubling, i.e. linear)
//
// So the assertion is a RATIO, never an absolute byte count: four times the
// input must cost at most five times the heap. Linear is ~4x, quadratic is
// ~16x, and the bound is machine-independent, which an absolute number would
// not be.
def fill(n: long) -> str {
    let s = "";
    let i = 0;
    while (i < n) { s += "a"; i = i + 1 };
    s
};

type Cost = { bytes: long, len: long };

// What json.esc() allocates for a string of n characters: heap_used() is read
// after the input is built and before the result is looked at, so neither end
// lands inside the measurement.
def esc_cost(n: long) -> Cost {
    let s = fill(n);
    let b0 = heap_used();
    let out = json.esc(s);
    let b1 = heap_used();
    { bytes: b1 - b0, len: out.length }
};

// The same escaper with the value-used append on purpose -- `{ out += x };`,
// the shape esc() used to have. It is here so the ratio assertion below is
// known to be able to FAIL: a guard that cannot fail is not a check. If the
// filed compiler bug is ever fixed upstream, this control is the line that
// goes red, and the honest response is to re-verify the filing in BUGS.md and
// then delete the twin -- not to relax the bound above.
def esc_cost_value_used(n: long) -> Cost {
    let s = fill(n);
    let b0 = heap_used();
    let out = esc_value_used(s);
    let b1 = heap_used();
    { bytes: b1 - b0, len: out.length }
};

// The quadratic twin. It is NOT a general escaper and must not be mistaken for
// one: it knows only the quote, and this check only ever feeds it plain ASCII.
// What it reproduces is the *shape* -- `+=` as the last statement of an arm.
def esc_value_used(s: str) -> str {
    let out = "\"";
    let i = 0;
    let go = true;
    while (go) {
        if (i < s.length) {
            let c = s[i];
            // NO `;` inside the braces, and a `;` after them: both spellings
            // are value-used, which is the whole point of this copy.
            if (c == 34) { out += "\\\"" }
            else { out += chr(c) };
            i = i + 1;
        } else { go = false };
    };
    out + "\""
};

// An object with `n` distinct short keys, so emitting it measures json.emit()'s
// separator append as well as the esc() behind it.
def wide_tree(n: long) -> json.Json {
    let keys: [str] = [];
    let vals: [json.Json] = [];
    let i = 0;
    while (i < n) {
        keys += "k" + tostring(i);
        vals += json.num_node(tostring(i % 10), i % 10);
        i = i + 1;
    };
    json.obj_node(keys, vals)
};

def emit_cost(n: long) -> Cost {
    let t = wide_tree(n);
    let b0 = heap_used();
    let out = json.emit(t);
    let b1 = heap_used();
    { bytes: b1 - b0, len: out.length }
};

// A ratio in tenths, so the report needs no float (there is no float -> long).
def tenths(a: long, b: long) -> long {
    if (b <= 0) { return 0 - 1 };
    a * 10 / b
};

def show_tenths(t: long) -> str {
    let whole = t / 10;
    let frac = t - whole * 10;
    if (frac < 0) { return tostring(whole) };
    tostring(whole) + "." + tostring(frac) + "x"
};

def linear(c: Count, verbose: bool) -> Count {
    print("F. the writer allocates linearly: 4x the input, at most 5x the heap");
    // A warm call first, so a one-time cost cannot land in a measurement.
    let warm = esc_cost(8);
    c = verdict(c, warm.len == 10, "a warm call is measured too: 8 bytes in, 10 out",
                "got " + tostring(warm.len));
    let n = 1600;
    let small = esc_cost(n);
    let big = esc_cost(n * 4);
    c = verdict(c, small.len == n + 2 && big.len == n * 4 + 2,
                "esc() returns the input plus the two quotes",
                "got " + tostring(small.len) + " at n=" + tostring(n)
                + " and " + tostring(big.len) + " at 4n");
    let r = tenths(big.bytes, small.bytes);
    c = verdict(c, big.bytes <= small.bytes * 5,
                "esc() heap grows at most 5x for 4x the input (quadratic is ~16x)",
                "n=" + tostring(n) + ": " + tostring(small.bytes) + " B, 4n="
                + tostring(n * 4) + ": " + tostring(big.bytes) + " B, ratio "
                + show_tenths(r));
    // The teeth: the value-used twin of the same loop, which is what esc() was.
    let qsmall = esc_cost_value_used(400);
    let qbig = esc_cost_value_used(1600);
    let qr = tenths(qbig.bytes, qsmall.bytes);
    c = verdict(c, qbig.bytes >= qsmall.bytes * 8,
                "the value-used append IS still quadratic (so the guard above can fail)",
                "400: " + tostring(qsmall.bytes) + " B, 1600: " + tostring(qbig.bytes)
                + " B, ratio " + show_tenths(qr));
    c = verdict(c, qbig.bytes > small.bytes * 8,
                "at the same input size the value-used escaper costs over 8x the in-place one",
                "at n=1600: value-used " + tostring(qbig.bytes) + " B vs in-place "
                + tostring(small.bytes) + " B");
    // emit() too: its separator append sits in the same kind of loop, and a
    // comma between two keys is not visible in a five-key document.
    let wsmall = emit_cost(400);
    let wbig = emit_cost(1600);
    c = verdict(c, wbig.bytes <= wsmall.bytes * 5,
                "emit() heap grows at most 5x for 4x the keys",
                "400 keys: " + tostring(wsmall.bytes) + " B, 1600 keys: "
                + tostring(wbig.bytes) + " B, ratio " + show_tenths(tenths(wbig.bytes, wsmall.bytes)));
    // ...and the fast path changed nothing about what comes out: the emitted
    // document still parses, keeps every key in order, and re-emits byte for
    // byte. A separator append that dropped or duplicated a comma would pass
    // the ratio above and fail this. A smaller tree here on purpose: this half
    // is about the bytes, not the cost.
    let wire = json.emit(wide_tree(200));
    let d = json.parse(wire);
    c = verdict(c, d.ok, "a 200-key document still parses after the change", d.err);
    c = verdict(c, json.emit(d.val) == wire, "and re-emits byte-identically");
    c = verdict(c, json.emit(wide_tree(3)) == "{\"k0\":0,\"k1\":1,\"k2\":2}",
                "emit() output is unchanged: three short keys, in order, comma-separated",
                json.emit(wide_tree(3)));
    if (verbose) {
        print("        esc " + tostring(n) + " -> " + tostring(small.bytes) + " B, 4n -> "
              + tostring(big.bytes) + " B; value-used 400 -> " + tostring(qsmall.bytes)
              + " B, 1600 -> " + tostring(qbig.bytes) + " B");
    };
    c
};

// ── the driver ─────────────────────────────────────────────────────────

def run_self(verbose: bool) -> long {
    print("weather --check: property checks (no golden file is involved)");
    print("");
    let lfd = net.socket_tcp();
    let b = net.bind_tcp(lfd, 0);
    if (b < 0) {
        eputs("check: cannot bind a loopback socket" + "\n");
        return 1;
    };
    let port = net.local_port(lfd);
    net.listen_fd(lfd, 16);
    let pid = fork { wxsrv.serve_forever(lfd); 0 };
    net.close_fd(lfd);
    sleep(150);

    let c: Count = { pass: 0, fail: 0 };
    c = roundtrip(c, verbose);
    print("");
    c = errpaths(c, port, verbose);
    print("");
    c = conv(c);
    print("");
    c = bad(c, verbose);
    print("");
    c = linear(c, verbose);

    syscall(62, pid, 15);
    let st = wait_pid(pid);
    print("");
    print("local service exited " + tostring(st) + " (143 = SIGTERM)");
    // The heap is an arena and nothing is freed, so the number of bytes this
    // check has cost is worth printing rather than guessing at: it parses
    // the same documents hundreds of times on purpose, which is exactly why
    // it stays far inside the 3.5 GiB cap.
    print("heap used: " + tostring(heap_used()) + " B");
    print(tostring(c.pass) + " passed, " + tostring(c.fail) + " failed");
    if (c.fail == 0) {
        print("RESULT: ok");
        0
    } else {
        print("RESULT: FAILED");
        1
    }
};

export { TAG, Count, run_self, verdict, roundtrip, errpaths, conv, bad, linear, refuse, whole_numbers,
         report_of, Seen, Refused, ask, CONVS, MPHS, BADS, Bad, Conv, deep_doc, Cost, esc_cost };
