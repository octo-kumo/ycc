// Expand target policy once; ordinary compiler code consumes the descriptors.
#{
    import schema from "./target_schema.y";
    let out = "type TargetInfo = {name: str, format: str, runtime: [str], threads: str, sysregs: [long], stack_room: long, stack_base: long};\n";
    let entries = "";
    let lookup = "";
    let known = "";
    let names = "";
    for i in 0..len(schema.TARGET_PLATFORMS) {
        let p = schema.TARGET_PLATFORMS[i].split("|");
        let files = "";
        foreach (file in p[2].split(",")) {
            if (files != "") { files += ","; };
            files += "\"" + file + "\"";
        };
        if (i > 0) { entries += ","; known += " || "; names += ", "; };
        entries += "{name: \"" + p[0] + "\", format: \"" + p[1] + "\", runtime: [" + files +
            "], threads: \"" + p[3] + "\", sysregs: [" + p[4] + "], stack_room: " + p[5] + ", stack_base: " + p[6] + "}";
        lookup += "if (name == \"" + p[0] + "\") { return target_table[" + tostring(i) + "]; };\n";
        known += "name == \"" + p[0] + "\"";
        names += p[0];
    };
    out + "let target_table: [TargetInfo] = [" + entries + "];\n" +
        "def target_info(name: str) -> TargetInfo {" + lookup + "target_table[0] };\n" +
        "def target_known(name: str) -> bool { " + known + " };\n" +
        "def target_names() -> str { \"" + names + "\" };\n" +
        "def target_arch_name() -> str { \"" + schema.TARGET_ARCH.name + "\" };\n" +
        "def target_word() -> long { " + tostring(schema.TARGET_ARCH.word) + " };\n"
}#
