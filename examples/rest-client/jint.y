// jint.y -- a JSON number that has to BE an integer.
//
//   import jint;
//   let n = jint.of(v);          // 0, and jint.err says why, if it was not one
//
// This folder used to carry its own json.y: an extractive, offset-returning
// reader over a [byte; 65536] buffer that allocated nothing. It is gone --
// `import json;` now resolves to std/json.y, which builds a json.Val -- and
// this module is the one piece of the old reader that std's accessors do NOT
// replace.
//
// `json.as_long` TRUNCATES. It answers 1 for 1.5 and 1 for 1e3, because Y
// has no float-to-long conversion and json.as_long reaches for `tonum`, which
// reads the leading integer and stops. The old `json.int_at` refused both
// instead ("not an integer"), and refusing is the point: a REST body that
// says qty is 3.5 must not read back as 3, or a server and its client
// disagree about the data with nothing on the wire to show it.
//
// So the check is on the number's LITERAL TEXT, which is exactly what json.Val
// keeps (a number is json.numtext, not a number, and that is what makes
// stringify byte-exact). Two bounds, both the old reader's:
//
//   * a fraction or an exponent is refused, not truncated
//   * more than 13 digits is "integer too large", so a value that would wrap
//     a long is an error rather than a wrapped lie
//
// `err` is "" on success and is set by `of`, so check the return value and
// read `err` only when it is 0 and you expected otherwise -- the same shape
// the old json.iok / json.ival pair had.

import json;

let err = "";            // "" when the last of() read an integer

// of(v: json.Val) -> long -- the integer payload of v, or 0 with `err`
// naming what was wrong with it.
def of(v: json.Val) -> long {
    err = "";
    let out = 0;
    if let json.Num n = v {
        let t = n.num;
        let ndig = 0;
        let clean = true;
        let i = 0;
        while (i < len(t)) {
            let c = byte_at(t, i);
            if (c >= 48 && c <= 57) { ndig = ndig + 1 }
            else if (!(c == 45 && i == 0)) { clean = false };
            i = i + 1
        };
        if (ndig > 13) { err = "integer too large" }
        else if (!clean || ndig == 0) { err = "not an integer" }
        else { out = tonum(t) }
    } else {
        err = "not a number"
    };
    out
};

export { err, of };