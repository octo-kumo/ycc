#{
    let j = "";
    for i in 0..len(YCC.args) {
        if (i > 0) { j += ","; };
        j += YCC.args[i];
    };
    "def b_args() -> str { " + ycc_quote(j) + " };"
}#
