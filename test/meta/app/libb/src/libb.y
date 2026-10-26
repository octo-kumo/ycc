#{
    let v = ycc_define("LEVEL");
    let lv = if (v == none) { "none" } else { v! };
    "def b_level() -> str { " + ycc_quote(lv) + " };"
}#
