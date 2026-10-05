// wxlive.y -- the two legs that are not the loopback one: real TLS against
// openssl s_server, and the real open-meteo.com API.
//
// ── leg 2, TLS ──────────────────────────────────────────────────────────
//
// tls.y is CLIENT-ONLY: it has client_hello, server_hello and cert_list but
// no accept, so a TLS server in Y is not possible and the hermetic TLS leg
// has to borrow one. openssl s_server is it -- the same precedent
// test_net.sh already uses for std/tls.y. No internet, and the certificate
// is generated at run time.
//
// The client verifies it with `anchors:`, which is PEM TEXT, not a path: it
// goes straight to x509.anchors_pem(). anchors is left unset for --live,
// which is what makes that leg use the SYSTEM trust store.
//
// Two facts cost time here and are worth writing down:
//
//  * x509's name check reads only the dNSName SANs (extension tag 0x82).
//    An iPAddress SAN (0x87) is parsed away and ignored, so a certificate
//    that names 127.0.0.1 the correct way -- `subjectAltName=IP:127.0.0.1` --
//    fails with "certificate is not valid for 127.0.0.1". The generated
//    certificate therefore carries BOTH `DNS:127.0.0.1` and `IP:127.0.0.1`.
//    Filed in examples/SUGGESTIONS.md; grep for "iPAddress" there.
//
//  * s_server serves whatever arrives on its stdin, so the canned response
//    is piped in. -ign_eof is required or stdin EOF closes the listener.
//
// ── leg 3, live ────────────────────────────────────────────────────────
//
// open-meteo.com needs no API key, which is the whole reason it is here:
// this example bundles no key and never will. It is a free service and it
// rate-limits, so --live may fail with 429 and that is the service's
// answer, not a defect in this program. It is never in EXPECTED.
//
// The real service answers in FLOAT degrees, and there is no float -> long
// conversion and no cast syntax (ORCHESTRATOR.md 2.4a), so a float is
// formatted to a fixed number of decimals and read back with an integer
// parser: f"{v:.0f}" for a temperature, dec_e5 below for a coordinate. That
// is the documented cost of the gap, and it is visible here rather than
// hidden.

import http;
import fs;
import net;
import json;
import wxfmt;
import wxdata;

const TAG = "wx.v1";
const TLS_DIR = "/tmp/opencode/wx-tls";
const GEO = "https://geocoding-api.open-meteo.com/v1/search";
const API = "https://api.open-meteo.com/v1/forecast";

// ── leg 2: openssl s_server on loopback ────────────────────────────────

type Tls = { ok: bool, pid: long, port: long, pem: str, msg: str };

// Nothing here fails the program. If openssl is missing, or will not make a
// certificate, or never answers, --tls says so on stderr and exits 3. The
// default leg does not touch this function at all.
def start_tls() -> Tls {
    if (!have_openssl()) {
        return { ok: false, pid: 0, port: 0, pem: "",
                 msg: "--tls needs openssl on PATH (openssl s_server) and it is not "
                    + "there; the TLS leg is skipped. The default leg is plain HTTP "
                    + "and needs nothing. Skipping is not a failure of this program." };
    };
    ensure_dir();
    let cert = TLS_DIR + "/cert.pem";
    let key = TLS_DIR + "/key.pem";
    let rc = exec("openssl req -x509 -newkey rsa:2048 -keyout " + key + " -out " + cert
                + " -days 2 -nodes -subj /CN=127.0.0.1"
                + " -addext subjectAltName=DNS:127.0.0.1,IP:127.0.0.1 >/dev/null 2>&1");
    if (rc != 0) {
        return { ok: false, pid: 0, port: 0, pem: "",
                 msg: "openssl could not make a self-signed certificate (exit "
                    + tostring(rc) + "); the TLS leg is skipped" };
    };
    let pem = fs.read_file(cert);
    if (is_some(pem) == false) {
        return { ok: false, pid: 0, port: 0, pem: "",
                 msg: "the generated certificate " + cert + " could not be read back" };
    };
    let body = json.emit(wxdata.forecast_tree(wxdata.reykjavik()));
    let canned = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
               + "Content-Length: " + tostring(len(body)) + "\r\n"
               + "Connection: close\r\n\r\n" + body;
    let pid = 0;
    let port = 0;
    let up = false;
    // One retry: the port is probed by binding and releasing it, so a
    // process that grabs it in between costs one more attempt rather than a
    // confusing "connection refused" from the client.
    let tries = 0;
    while (!up && tries < 2) {
        port = free_port();
        pid = spawn_server(port, cert, key, canned);
        up = wait_alive(pid);
        if (!up && pid > 0) { syscall(62, pid, 15) };
        tries = tries + 1;
    };
    if (!up) {
        return { ok: false, pid: 0, port: 0, pem: "",
                 msg: "openssl s_server did not stay up on 127.0.0.1:" + tostring(port)
                    + "; the TLS leg is skipped. " + server_says() };
    };
    { ok: true, pid: pid, port: port, pem: unwrap(pem), msg: "" }
};

def have_openssl() -> bool {
    exec("openssl version >/dev/null 2>&1") == 0
};

def ensure_dir() -> void {
    if (!fs.exists(TLS_DIR)) {
        exec("mkdir -p " + TLS_DIR + " >/dev/null 2>&1");
    }
};

def free_port() -> long {
    let fd = net.socket_tcp();
    let b = net.bind_tcp(fd, 0);
    let port = 0;
    if (b >= 0) {
        port = net.local_port(fd);
        net.close_fd(fd);
    };
    port
};

// `exec` is /bin/sh -c and blocks until the command finishes, so the server
// is backgrounded and its pid written to a file. $! is the pid of the
// process sh forked for it, which is s_server itself. Its own chatter goes
// to a log file, not to /dev/null: if it refuses to start, the reason is
// worth quoting, and the report must not have openssl noise spliced into it.

// quote concerns at all: the response is written to a file and cat feeds it.
// The canned response goes to a FILE and `cat` feeds it in, rather than
// being interpolated into the shell command. A shell single-quoted string
// would have to survive the JSON, which means the JSON may never contain an
// apostrophe; a file has no such rule, and `cat` cannot mangle the bytes.
def spawn_server(port: long, cert: str, key: str, canned: str) -> long {
    let pidfile = TLS_DIR + "/s_server.pid";
    let log = TLS_DIR + "/s_server.log";
    let bodyfile = TLS_DIR + "/canned.http";
    if (!fs.write_file(bodyfile, canned)) {
        return 0;
    };
    let cmd = "cat " + bodyfile + " | openssl s_server -accept " + tostring(port)
            + " -cert " + cert + " -key " + key + " -quiet -ign_eof"
            + " >" + log + " 2>&1 & echo $! > " + pidfile;
    exec(cmd);
    let txt = fs.read_file(pidfile);
    if (is_some(txt) == false) { return 0 };
    let body = unwrap(txt).trim();
    let pid = 0;
    if (digits(body)) { pid = tonum(body) };
    pid
};

// Wait for the listener to exist WITHOUT connecting to it. A probe
// connection is a TCP connect that never sends a ClientHello, which s_server
// treats as a broken handshake -- it logged one and the client's own
// handshake then failed. Liveness is the right question here and
// kill(pid, 0) answers it: syscall 62 is kill, and signal 0 tests for
// existence without delivering anything.
def wait_alive(pid: long) -> bool {
    let tries = 0;
    let up = false;
    // A first settle of half a second: s_server loads a key and a
    // certificate before it listens, and a client that arrives inside that
    // window gets a connection that is then closed -- which the client
    // reports as a broken connection rather than as "not ready".
    sleep(500);
    while (!up && tries < 20) {
        sleep(100);
        if (syscall(62, pid, 0) == 0) { up = true } else { tries = tries + 1 };
    };
    up
};

// What s_server said, if anything, so a skip is never a bare "it failed".
def server_says() -> str {
    let txt = fs.read_file(TLS_DIR + "/s_server.log");
    if (is_some(txt) == false) { return "" };
    let body = unwrap(txt).trim();
    if (body.length > 0) { "openssl said: " + body + "\n" } else { "" }
};

// ── leg 3: the live service ────────────────────────────────────────────

type Answer = { ok: bool, body: str, msg: str };

def no(msg: str) -> Answer { { ok: false, body: "", msg: msg } };

// One city, one forecast, in the same wx.v1 shape the local service emits,
// so the renderer and every conversion below are the same code on all
// three legs. Anchors are deliberately left unset: --live is the leg that
// should use the SYSTEM trust store.
def fetch(city: str, days: long) -> Answer {
    let g = http.get(GEO + "?name=" + wxfmt.pct(city) + "&count=1", { timeout: 20 });
    if (g.status != 200) {
        let note = "";
        if (g.status == 429) {
            note = " (rate limited: the live leg talks to a free service, not politely throttled)";
        };
        return no("open-meteo geocoding answered HTTP " + tostring(g.status)
                + " " + g.reason + note);
    };
    let gbody = g.text();
    let gd = json.parse(gbody);
    if (!gd.ok) {
        return no("the geocoding answer is not JSON at byte " + tostring(gd.at) + ": " + gd.err);
    };
    let hits = json.arr_of(gd.val, "results");
    if (hits.length == 0) {
        return no("open-meteo knows no place called '" + city + "'");
    };
    let hit = hits[0];
    let lat = lat_text(hit);
    let lon = lon_text(hit);
    let url = API + "?latitude=" + lat + "&longitude=" + lon
            + "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,"
            + "relative_humidity_2m,surface_pressure"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,"
            + "wind_speed_10m_max&forecast_days=" + tostring(days) + "&timezone=UTC";
    let f = http.get(url, { timeout: 25 });
    if (f.status != 200) {
        let note = "";
        if (f.status == 429) {
            note = " (rate limited: the live leg talks to a free service)";
        };
        return no("open-meteo answered HTTP " + tostring(f.status)
                + " " + f.reason + note);
    };
    let body = f.text();
    let fd = json.parse(body);
    if (!fd.ok) {
        return no("the forecast answer is not JSON at byte " + tostring(fd.at) + ": " + fd.err);
    };
    { ok: true, body: json.emit(adapt(hit, fd.val, lat, lon)), msg: "" }
};

// A JSON number arrives as text; the URL wants it back in full precision,
// so the raw text is passed through rather than through a float.
def lat_text(hit: json.Json) -> str {
    let v = json.obj(hit, "latitude");
    if (v.kind == "num") { v.s } else { "0" }
};

def lon_text(hit: json.Json) -> str {
    let v = json.obj(hit, "longitude");
    if (v.kind == "num") { v.s } else { "0" }
};

// Rebuild the document the local service emits, from the live one. Every
// float becomes an integer through an f-string spec, because there is no
// float -> long and no cast (ORCHESTRATOR.md 2.4a).
def adapt(hit: json.Json, doc: json.Json, lat: str, lon: str) -> json.Json {
    let cur = json.obj(doc, "current");
    let daily = json.obj(doc, "daily");
    let times = json.arr_of(daily, "time");
    let codes = json.arr_of(daily, "weather_code");
    let maxs = json.arr_of(daily, "temperature_2m_max");
    let mins = json.arr_of(daily, "temperature_2m_min");
    let mms = json.arr_of(daily, "precipitation_sum");
    let winds = json.arr_of(daily, "wind_speed_10m_max");
    let rows: [json.Json] = [];
    let i = 0;
    while (i < times.length) {
        rows += json.obj_node(
            ["date", "code", "min_c", "max_c", "precip_mm", "wind_kmph"],
            [json.str_node(json.text(times[i])),
             deg_int(json.nth(codes, i)),
             deg_int(json.nth(mins, i)),
             deg_int(json.nth(maxs, i)),
             deg_int(json.nth(mms, i)),
             deg_int(json.nth(winds, i))]);
        i = i + 1;
    };
    json.obj_node(
        ["schema", "location", "current", "daily"],
        [json.str_node(TAG),
         json.obj_node(["name", "region", "country", "lat", "lon", "tz"],
                       [json.str_node(json.str_of(hit, "name")),
                        json.str_node(json.str_of(hit, "admin1")),
                        json.str_node(json.str_of(hit, "country")),
                        // The wire form carries the WHOLE number, never the
                        // fraction open-meteo sent: a json number with a
                        // fraction keeps only its text, so re-reading
                        // -0.22985 would give 0 and the report would print
                        // 0.00000. wx.v1 is integers all the way down.
                        json.num_node(tostring(dec_e5(lat)), dec_e5(lat)),
                        json.num_node(tostring(dec_e5(lon)), dec_e5(lon)),
                        json.str_node(json.str_of(hit, "timezone"))]),
         json.obj_node(["time", "code", "temp_c", "feels_like_c", "wind_kmph",
                        "humidity", "pressure_hpa"],
                       [json.str_node(json.str_of(cur, "time")),
                        code_int(json.obj(cur, "weather_code")),
                        deg_int(json.obj(cur, "temperature_2m")),
                        deg_int(json.obj(cur, "apparent_temperature")),
                        deg_int(json.obj(cur, "wind_speed_10m")),
                        deg_int(json.obj(cur, "relative_humidity_2m")),
                        deg_int(json.obj(cur, "surface_pressure"))]),
         json.arr_node(rows)])
};

// A float field as a whole number. There is no float -> long and no cast
// (ORCHESTRATOR.md 2.4a), so the LITERAL TEXT is parsed here and rounded
// with integer arithmetic: the first fraction digit decides, and the sign is
// applied to the rounded magnitude, so -3.5 is -4 and -3.4 is -3 -- the same
// answer printf's %.0f gives, computed without a float.
def deg_int(v: json.Json) -> json.Json {
    if (v.kind == "num" || v.kind == "str") { num_int(dec0(v.s)) } else { num_int(0) }
};

def code_int(v: json.Json) -> json.Json {
    if (v.kind == "num" || v.kind == "str") { num_int(dec0(v.s)) } else { num_int(0) }
};

def num_int(n: long) -> json.Json { json.num_node(tostring(n), n) };

def digits(t: str) -> bool {
    let ok = t.length > 0;
    let i = 0;
    while (i < t.length) {
        let c = ord(t[i:i + 1]);
        if (c < 48 || c > 57) { ok = false };
        i = i + 1;
    };
    ok
};

// A decimal literal to a whole number, ties away from zero. Exponent
// notation is not accepted: no free service in this example's --live path
// uses it, and pretending otherwise would be a silent wrong number.
def dec0(t: str) -> long {
    let s = t;
    let neg = s.length > 0 && s[0:1] == "-";
    if (neg) { s = s[1:s.length] };
    let dot = index_of(s, ".");
    let w = 0;
    let up = 0;
    if (dot < 0) {
        if (digits(s)) { w = tonum(s) };
    } else {
        let a = s[0:dot];
        if (digits(a)) { w = tonum(a) };
        let frac = s[dot + 1:s.length];
        if (frac.length > 0) {
            let c = ord(frac[0:1]);
            if (c >= 53 && c <= 57) { up = 1 };
        };
    };
    let v = w + up;
    if (neg && v != 0) { 0 - v } else { v }
};

// A decimal literal to hundred-thousandths, in integers: "-21.9426" is
// -2194260. This is the coordinate path where a float would have to be
// converted, and there is no conversion, so the text is parsed by hand --
// which is also why it is exact where f-string formatting would not be.
def dec_e5(t: str) -> long {
    let s = t;
    let neg = false;
    if (s.length > 0 && s[0:1] == "-") {
        neg = true;
        s = s[1:s.length];
    };
    let dot = index_of(s, ".");
    let whole = 0;
    let frac = "";
    if (dot < 0) {
        if (digits(s)) { whole = tonum(s) };
    } else {
        let w = s[0:dot];
        if (digits(w)) { whole = tonum(w) };
        frac = s[dot + 1:s.length];
    };
    let f = 0;
    let scale = 10000;
    let i = 0;
    while (i < frac.length && i < 5) {
        let c = ord(frac[i:i + 1]);
        if (c >= 48 && c <= 57) { f = f + (c - 48) * scale };
        scale = scale / 10;
        i = i + 1;
    };
    let v = whole * 100000 + f;
    if (neg) { 0 - v } else { v }
};

def wxsrv_pct(s: str) -> str { wxfmt.pct(s) };

export { TAG, TLS_DIR, GEO, API, Tls, Answer, start_tls, have_openssl, free_port,
         spawn_server, wait_alive, server_says, fetch, adapt, deg_int, code_int, num_int, digits,
         dec0, dec_e5, wxsrv_pct };
