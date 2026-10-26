// The build a generator sees (S15): -D/-U and escaping.
#{
    let s = "";
    let t = ycc_define("TEXT");
    if (t != none) { s += "print(" + ycc_quote(t!) + ");" + chr(10); };
    let d = ycc_define("DEFAULT");
    if (d != none) { s += "print(" + ycc_quote(d!) + ");" + chr(10); };
    let q = ycc_define("EQ");
    if (q != none) { s += "print(" + ycc_quote(q!) + ");" + chr(10); };
    let gone = if (ycc_defined("GONE")) { "yes" } else { "no" };
    let dn = "";
    foreach (n in YCC.defines) { if (dn != "") { dn += ","; }; dn += n; };
    s += "print(" + ycc_quote(dn) + ");" + chr(10);
    s += "print(" + ycc_quote(gone) + ");" + chr(10);
    s
}#
