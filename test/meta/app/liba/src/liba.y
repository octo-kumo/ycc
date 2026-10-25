#{
    let v = ycc_define("LEVEL");
    let lv = if (v == none) { "none" } else { v! };
    let gone = if (ycc_defined("GONE")) { "yes" } else { "no" };
    "def a_level() -> str { " + ycc_quote(lv) + " };" + chr(10) +
    "def a_gone() -> str { " + ycc_quote(gone) + " };"
}#
