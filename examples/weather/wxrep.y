// wxrep.y -- the report renderer.
//
// It works on the PARSED json.Json tree and nothing else. It never sees
// wxdata's records, so what it prints is what came over the wire. Every
// field goes through json's total accessors, which answer a documented
// default for anything missing, so a truncated or partial document renders
// a visibly incomplete report instead of trapping -- but the client checks
// the schema first, so an incomplete document never gets this far.
//
// The unit arithmetic is here, in integers: wxfmt.c_to_f turns the Celsius
// the service sent into the Fahrenheit the report shows, and
// wxfmt.kmh_to_mph10 does the same for the wind. Nothing here is a float
// and nothing here is a cast.

import json;
import wxfmt;

const CW_DATE = 10;       // 2026-01-15
const CW_WMO = 3;         // 71
const CW_COND = 13;       // thunderstorm
const CW_TEMP = 5;        // -40, plus the unit in the header
const CW_MM = 7;          // 12 mm
const CW_WIND = 8;        // 24 km/h

// One location: identity, current conditions, then the daily table.
def render(t: json.Json, days: long) -> str {
    let loc = json.obj(t, "location");
    let cur = json.obj(t, "current");
    let lat = json.int_of(loc, "lat");
    let lon = json.int_of(loc, "lon");
    let out = json.str_of(loc, "name") + " -- " + json.str_of(loc, "region")
            + ", " + json.str_of(loc, "country") + "\n";
    out += "  " + wxfmt.lpad(wxfmt.deg(wxfmt.magnitude(lat)), 9) + " " + (lat < 0 ? "S" : "N")
         + "   " + wxfmt.lpad(wxfmt.deg(wxfmt.magnitude(lon)), 9) + " " + (lon < 0 ? "W" : "E")
         + "   tz " + json.str_of(loc, "tz") + "\n";
    out += now_line(cur);
    out += table(json.arr_of(t, "daily"), days)
};

def now_line(cur: json.Json) -> str {
    let code = json.int_of(cur, "code");
    let t = json.int_of(cur, "temp_c");
    let f = json.int_of(cur, "feels_like_c");
    let a = "  now   " + wxfmt.lpad(json.str_of(cur, "time"), 16)
          + "  " + cond(code)
          + "  " + wxfmt.lpad(wxfmt.deg_c(t), 7)
          + " = " + wxfmt.lpad(wxfmt.deg_f(wxfmt.c_to_f(t)), 7)
          + "   feels " + wxfmt.lpad(wxfmt.deg_c(f), 7)
          + " = " + wxfmt.deg_f(wxfmt.c_to_f(f)) + "\n";
    let b = "  wind  " + wxfmt.lpad(wind_str(json.int_of(cur, "wind_kmph")), 22)
          + "   humidity " + wxfmt.lpad(hum(json.int_of(cur, "humidity")), 4)
          + "   pressure " + wxfmt.lpad(tostring(json.int_of(cur, "pressure_hpa")), 5)
          + " hPa\n";
    a + b
};

// One fixed-width "condition" cell: the pictogram in its own column, then
// the description padded to the width of the longest one ("partly cloudy").
// lpad/rpad only ever PAD -- a cell wider than its column pushes the whole
// row right -- so the width has to be the longest text, not the average.
def cond(code: long) -> str {
    wxfmt.glyph(code) + " " + wxfmt.rpad(wxfmt.describe(code), CW_COND)
};

def wind_str(kmph: long) -> str { tostring(kmph) + " km/h = " + wxfmt.mph1(kmph) + " mph" };

def hum(v: long) -> str { tostring(v) + "%" };

// The multi-day table, at most `days` rows (0 or less means every row the
// document holds). Columns are aligned by display width, not bytes, so the
// three-byte snowflake does not push the numbers out.
def table(rows: [json.Json], days: long) -> str {
    let out = "\n  " + wxfmt.lpad("date", CW_DATE) + "  " + wxfmt.lpad("wmo", CW_WMO)
             + "  " + wxfmt.lpad("condition", CW_COND + 2)
             + "  " + wxfmt.lpad("min C", CW_TEMP) + "  " + wxfmt.lpad("max C", CW_TEMP)
             + "  " + wxfmt.lpad("min F", CW_TEMP) + "  " + wxfmt.lpad("max F", CW_TEMP)
             + "  " + wxfmt.lpad("precip", CW_MM)
             + "  " + wxfmt.lpad("wind", CW_WIND) + "\n";
    let i = 0;
    let go = true;
    while (go && i < rows.length) {
        if (days > 0 && i >= days) { go = false } else {
            let r = rows[i];
            let code = json.int_of(r, "code");
            let lo = json.int_of(r, "min_c");
            let hi = json.int_of(r, "max_c");
            out += "  " + wxfmt.lpad(json.str_of(r, "date"), CW_DATE)
                 + "  " + wxfmt.lpad(tostring(code), CW_WMO)
                 + "  " + wxfmt.lpad(cond(code), CW_COND + 2)
                 + "  " + wxfmt.lpad(tostring(lo), CW_TEMP)
                 + "  " + wxfmt.lpad(tostring(hi), CW_TEMP)
                 + "  " + wxfmt.lpad(tostring(wxfmt.c_to_f(lo)), CW_TEMP)
                 + "  " + wxfmt.lpad(tostring(wxfmt.c_to_f(hi)), CW_TEMP)
                 + "  " + wxfmt.lpad(tostring(json.int_of(r, "precip_mm")) + " mm", CW_MM)
                 + "  " + wxfmt.lpad(wind_str(json.int_of(r, "wind_kmph")), CW_WIND)
                 + "\n";
            i = i + 1;
        };
    };
    out
};

// ── the --list table, from /v1/locations ────────────────────────────────
//
// Left-aligned text columns: a slug, a name and a country are words, and
// right-aligning them makes the table look like it is falling over. The
// widths are the longest value in each column, so nothing is pushed out.
const CW_SLUG = 13;
const CW_NAME = 13;
const CW_COUNTRY = 11;
const CW_DEG = 13;

def render_locations(t: json.Json) -> str {
    let rows = json.arr_of(t, "locations");
    let out = "  " + wxfmt.rpad("slug", CW_SLUG) + "  " + wxfmt.rpad("name", CW_NAME)
             + "  " + wxfmt.rpad("country", CW_COUNTRY)
             + "  " + wxfmt.lpad("latitude", CW_DEG) + "  "
             + wxfmt.lpad("longitude", CW_DEG) + "\n";
    let i = 0;
    while (i < rows.length) {
        let r = rows[i];
        let lat = json.int_of(r, "lat");
        let lon = json.int_of(r, "lon");
        out += "  " + wxfmt.rpad(json.str_of(r, "slug"), CW_SLUG)
             + "  " + wxfmt.rpad(json.str_of(r, "name"), CW_NAME)
             + "  " + wxfmt.rpad(json.str_of(r, "country"), CW_COUNTRY)
             + "  " + wxfmt.lpad(wxfmt.deg(wxfmt.magnitude(lat)) + " " + (lat < 0 ? "S" : "N"), CW_DEG)
             + "  " + wxfmt.lpad(wxfmt.deg(wxfmt.magnitude(lon)) + " " + (lon < 0 ? "W" : "E"), CW_DEG)
             + "\n";
        i = i + 1;
    };
    out
};

export { CW_DATE, CW_WMO, CW_COND, CW_TEMP, CW_MM, CW_WIND,
         CW_SLUG, CW_NAME, CW_COUNTRY, CW_DEG,
         render, now_line, wind_str, cond, table, render_locations };
