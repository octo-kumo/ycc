// wxdata.y -- the canned forecast, and the JSON the local service emits.
//
// This is the SERVER side of the round trip. It holds the values as typed
// records -- what the service *intends* to say -- and turns them into a
// json.Json tree, which json.emit then writes out. The client never sees
// these records; it sees only the bytes. So `weather --check` can compare
// what the parser read against what this file meant, field by field, which
// is a claim no golden file can make.
//
// Every number here is an integer, on purpose. The service reports in
// whole degrees Celsius, so the client has to do the unit arithmetic in
// integers too (ORCHESTRATOR.md 2.4a: no float -> long, no cast syntax).
// Coordinates are hundred-thousandths of a degree (1e-5 deg is about 11 m),
// so a latitude is a `long` and not a float either.
//
// Longyearbyen is in the set for one reason: its current temperature is
// exactly -40 C, the one point where the Celsius and Fahrenheit scales
// coincide. It is there so the report contains a conversion a reader can
// check by eye, and so --check asserts the boundary rather than trusting it.

import json;

type Day = {
    date: str, code: long, min_c: long, max_c: long, precip_mm: long, wind_kmph: long
};

type Current = {
    time: str, code: long, temp_c: long, feels_like_c: long,
    wind_kmph: long, humidity: long, pressure_hpa: long
};

type Place = {
    slug: str, name: str, region: str, country: str,
    lat: long, lon: long, tz: str, current: Current, days: [Day]
};

// ── the data ────────────────────────────────────────────────────────────

def places() -> [Place] {
    let out: [Place] = [];
    out += reykjavik();
    out += nairobi();
    out += quito();
    out += ushuaia();
    out += longyearbyen();
    out
};

def reykjavik() -> Place {
    let c: Current = {
        time: "2026-01-15T12:00", code: 71, temp_c: -3, feels_like_c: -7,
        wind_kmph: 24, humidity: 81, pressure_hpa: 1002
    };
    let d: [Day] = [];
    d += day("2026-01-15", 71, -8, -1, 2, 24);
    d += day("2026-01-16", 73, -9, -2, 4, 28);
    d += day("2026-01-17", 3, -6, 0, 1, 22);
    d += day("2026-01-18", 61, -4, 2, 6, 19);
    { slug: "reykjavik", name: "Reykjavik", region: "Capital Region",
      country: "Iceland", lat: 6414660, lon: -2194260, tz: "Atlantic/Reykjavik",
      current: c, days: d }
};

def nairobi() -> Place {
    let c: Current = {
        time: "2026-01-15T15:00", code: 1, temp_c: 24, feels_like_c: 25,
        wind_kmph: 9, humidity: 58, pressure_hpa: 1013
    };
    let d: [Day] = [];
    d += day("2026-01-15", 1, 16, 27, 0, 8);
    d += day("2026-01-16", 2, 17, 28, 0, 10);
    d += day("2026-01-17", 80, 16, 26, 5, 12);
    d += day("2026-01-18", 3, 16, 25, 2, 9);
    { slug: "nairobi", name: "Nairobi", region: "Nairobi County",
      country: "Kenya", lat: -101792, lon: 3681930, tz: "Africa/Nairobi",
      current: c, days: d }
};

def quito() -> Place {
    let c: Current = {
        time: "2026-01-15T11:00", code: 3, temp_c: 12, feels_like_c: 11,
        wind_kmph: 7, humidity: 72, pressure_hpa: 1008
    };
    let d: [Day] = [];
    d += day("2026-01-15", 3, 6, 14, 3, 7);
    d += day("2026-01-16", 61, 7, 15, 9, 8);
    d += day("2026-01-17", 3, 6, 13, 4, 6);
    d += day("2026-01-18", 45, 5, 12, 2, 5);
    { slug: "quito", name: "Quito", region: "Pichincha",
      country: "Ecuador", lat: -17182, lon: -7846780, tz: "America/Guayaquil",
      current: c, days: d }
};

def ushuaia() -> Place {
    let c: Current = {
        time: "2026-01-15T14:00", code: 75, temp_c: -1, feels_like_c: -6,
        wind_kmph: 31, humidity: 88, pressure_hpa: 993
    };
    let d: [Day] = [];
    d += day("2026-01-15", 75, -3, 2, 6, 31);
    d += day("2026-01-16", 73, -5, 1, 8, 34);
    d += day("2026-01-17", 71, -7, 0, 5, 28);
    d += day("2026-01-18", 3, -6, 1, 2, 24);
    { slug: "ushuaia", name: "Ushuaia", region: "Tierra del Fuego",
      country: "Argentina", lat: -54558, lon: -6822200, tz: "America/Argentina/Ushuaia",
      current: c, days: d }
};

def longyearbyen() -> Place {
    let c: Current = {
        time: "2026-01-15T09:00", code: 73, temp_c: -40, feels_like_c: -53,
        wind_kmph: 41, humidity: 76, pressure_hpa: 1007
    };
    let d: [Day] = [];
    d += day("2026-01-15", 73, -44, -38, 3, 41);
    d += day("2026-01-16", 71, -46, -39, 4, 38);
    d += day("2026-01-17", 3, -43, -35, 1, 33);
    d += day("2026-01-18", 48, -41, -34, 2, 30);
    { slug: "longyearbyen", name: "Longyearbyen", region: "Svalbard",
      country: "Norway", lat: 7862340, lon: 1562200, tz: "Arctic/Longyearbyen",
      current: c, days: d }
};

def day(date: str, code: long, lo: long, hi: long, mm: long, wind: long) -> Day {
    { date: date, code: code, min_c: lo, max_c: hi, precip_mm: mm, wind_kmph: wind }
};

// ── lookup ──────────────────────────────────────────────────────────────

// A place by slug, or none. The lookup folds ASCII case, so it is the
// COMMAND LINE that accepts `--city Reykjavik`; the service does not, because
// wxsrv's query grammar is lower-case only and rejects an upper-case slug
// with a 400 before this is ever reached. That is deliberate: the CLI is for
// people and the wire format is not.
def find(slug: str) -> Place? {
    let want = ascii_lower(slug);
    let out: Place? = none;
    let ps = places();
    let i = 0;
    while (i < ps.length) {
        if (ps[i].slug == want) { out = some(ps[i]) };
        i = i + 1;
    };
    out
};

// ASCII case folding, for the command line. It is byte-wise and does not
// pretend to handle anything else: a slug is [a-z0-9_-] by the grammar, so
// A-Z is the only case there is to fold, and a UTF-8 byte is left alone.
def ascii_lower(s: str) -> str {
    let out = "";
    let i = 0;
    while (i < s.length) {
        let c = ord(s[i:i + 1]);
        // `;` inside the braces on purpose: this loop appends one byte per
        // character, and a value-used append (json.y's esc() explains why)
        // would copy the whole string each time round.
        if (c >= 65 && c <= 90) { out += chr(c + 32); } else { out += s[i:i + 1]; };
        i = i + 1;
    };
    out
};

def slugs() -> [str] {
    let ps = places();
    let out: [str] = [];
    let i = 0;
    while (i < ps.length) {
        out += ps[i].slug;
        i = i + 1;
    };
    out
};

// ── the wire format ─────────────────────────────────────────────────────
//
// schema "wx.v1" is the whole compatibility contract: the client refuses a
// document whose schema is not this string, so a future service can change
// the shape without the renderer quietly reading zeroes.

const SCHEMA = "wx.v1";

def day_tree(d: Day) -> json.Json {
    json.obj_node(["date", "code", "min_c", "max_c", "precip_mm", "wind_kmph"],
                  [json.str_node(d.date), json.num_node(tostring(d.code), d.code),
                   json.num_node(tostring(d.min_c), d.min_c),
                   json.num_node(tostring(d.max_c), d.max_c),
                   json.num_node(tostring(d.precip_mm), d.precip_mm),
                   json.num_node(tostring(d.wind_kmph), d.wind_kmph)])
};

def forecast_tree(p: Place) -> json.Json {
    let cur = p.current;
    let days: [json.Json] = [];
    let i = 0;
    while (i < p.days.length) {
        days += day_tree(p.days[i]);
        i = i + 1;
    };
    json.obj_node(
        ["schema", "location", "current", "daily"],
        [json.str_node(SCHEMA),
         json.obj_node(["name", "region", "country", "lat", "lon", "tz"],
                       [json.str_node(p.name), json.str_node(p.region),
                        json.str_node(p.country),
                        json.num_node(tostring(p.lat), p.lat),
                        json.num_node(tostring(p.lon), p.lon),
                        json.str_node(p.tz)]),
         json.obj_node(["time", "code", "temp_c", "feels_like_c", "wind_kmph",
                        "humidity", "pressure_hpa"],
                       [json.str_node(cur.time),
                        json.num_node(tostring(cur.code), cur.code),
                        json.num_node(tostring(cur.temp_c), cur.temp_c),
                        json.num_node(tostring(cur.feels_like_c), cur.feels_like_c),
                        json.num_node(tostring(cur.wind_kmph), cur.wind_kmph),
                        json.num_node(tostring(cur.humidity), cur.humidity),
                        json.num_node(tostring(cur.pressure_hpa), cur.pressure_hpa)]),
         json.arr_node(days)])
};

def locations_tree(ps: [Place]) -> json.Json {
    let items: [json.Json] = [];
    let i = 0;
    while (i < ps.length) {
        items += json.obj_node(["slug", "name", "country", "lat", "lon"],
                               [json.str_node(ps[i].slug), json.str_node(ps[i].name),
                                json.str_node(ps[i].country),
                                json.num_node(tostring(ps[i].lat), ps[i].lat),
                                json.num_node(tostring(ps[i].lon), ps[i].lon)]);
        i = i + 1;
    };
    json.obj_node(["schema", "locations"], [json.str_node(SCHEMA), json.arr_node(items)])
};

def error_tree(code: str, msg: str) -> json.Json {
    json.obj_node(["schema", "error"],
                  [json.str_node(SCHEMA),
                   json.obj_node(["code", "message"],
                                 [json.str_node(code), json.str_node(msg)])])
};

// A document that is *almost* right: the closing bracket is gone and the
// last member has no value. Served as 200 on purpose, so the client's
// parse-failure path is reachable over the wire and not only in --check.
const BROKEN = "{\"schema\":\"wx.v1\",\"location\":{\"name\":\"Nowhere\",";

// A document that PARSES perfectly and is still wrong: it carries the next
// schema's name. The parser cannot save the client here -- only the client's
// own refusal can -- which is what makes it the interesting case. A renderer
// that paints before it checks would produce a whole report from these bytes.
const WRONG_SCHEMA = "{\"schema\":\"wx.v2\",\"location\":{\"name\":\"Nowhere\","
    + "\"region\":\"\",\"country\":\"\",\"lat\":0,\"lon\":0,\"tz\":\"UTC\"},"
    + "\"current\":{\"time\":\"\",\"code\":0,\"temp_c\":0,\"feels_like_c\":0,"
    + "\"wind_kmph\":0,\"humidity\":0,\"pressure_hpa\":0},\"daily\":[]}";

export { SCHEMA, BROKEN, WRONG_SCHEMA, Day, Current, Place, places, reykjavik, nairobi, quito,
         ushuaia, longyearbyen, day, find, ascii_lower, slugs, day_tree,
         forecast_tree, locations_tree, error_tree };
