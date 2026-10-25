// wasm_shapes.y — WASM_OPS expanded once, at build time.
//
// The rows live in wasm_schema.y; this block turns them into WOP_* constants
// and the lookups wasm_enc.y uses: wop_code(n) is the opcode's fixed bytes
// (shared table entries, so the encoder's hot path allocates nothing) and
// wop_imm(n) names the dynamic immediate the encoder must write after it.
// The lookup is a small open-addressed hash table, because wb_op runs once per
// emitted instruction (millions of times for a large program).
#{
    import schema from "./wasm_schema.y";
    def hstr(s: str) -> long {
        let h = 2166136261;
        for i in 0..len(s) { h = ((h ^ s[i]) * 16777619) & 4294967295; };
        h
    };
    let hbits = 9;
    let hslots = 1 << hbits;
    let out = "";
    let names = "const WOP_NAMES: [str] = [";
    let codes = "const WOP_CODES: [[long]] = [";
    let imms = "def wop_imm(n: str) -> long {\n";
    let i = 0;
    while (i < len(schema.WASM_OPS)) {
        let row = schema.WASM_OPS[i];
        let p = row.split("|");
        let nm = p[0];
        let hex = p[1];
        let imm = "";
        if (len(p) > 2) { imm = p[2]; };
        let up = "";
        for k in 0..len(nm) {
            let c = nm[k];
            if (c == '.') { up += "_"; }
            else if (c >= 'a' && c <= 'z') { up += chr(c - 32); }
            else { up += c; };
        };
        let hs = hex.split(" ");
        let lit = "";
        let first = 0;
        for j in 0..len(hs) {
            let h = hs[j];
            let v = 0;
            for k in 0..len(h) {
                let c = h[k];
                let d = 0;
                if (c >= '0' && c <= '9') { d = c - '0'; }
                else if (c >= 'a' && c <= 'f') { d = c - 'a' + 10; }
                else { d = c - 'A' + 10; };
                v = v * 16 + d;
            };
            if (j == 0) { first = v; };
            if (lit != "") { lit += ", "; };
            lit += tostring(v);
        };
        let imc = 0;
        if (imm == "u32") { imc = 1; }
        else if (imm == "s32") { imc = 2; }
        else if (imm == "s64") { imc = 3; }
        else if (imm == "f64") { imc = 4; }
        else if (imm == "memarg") { imc = 5; }
        else if (imm == "bt") { imc = 6; }
        else if (imm == "br_table") { imc = 7; }
        else if (imm == "call") { imc = 8; }
        else if (imm == "call_indirect") { imc = 9; }
        else if (imm == "local") { imc = 10; }
        else if (imm == "global") { imc = 11; };
        out += "const WOP_" + up + " = " + tostring(first) + ";\n";
        if (i > 0) { names += ", "; codes += ", "; };
        names += "\"" + nm + "\"";
        codes += "[" + lit + "]";
        imms += "    if (n == \"" + nm + "\") { return " + tostring(imc) + "; };\n";
        i++;
    };
    names += "];\n";
    codes += "];\n";
    // Open addressing, linear probing, one-based entries (0 = empty slot).
    let slots: [long] = [];
    for k in 0..hslots { slots += 0; };
    let n = len(schema.WASM_OPS);
    let fi = 0;
    while (fi < n) {
        let row0 = schema.WASM_OPS[fi].split("|");
        let nm = row0[0];
        let h = hstr(nm) & (hslots - 1);
        let placed = false;
        while (!placed) {
            if (slots[h] == 0) { slots[h] = fi + 1; placed = true; }
            else { h = (h + 1) & (hslots - 1); };
        };
        fi++;
    };
    let sl = "const WOP_HASH: [long] = [";
    for k in 0..hslots {
        if (k > 0) { sl += ", "; };
        sl += tostring(slots[k]);
    };
    sl += "];\n";
    let hashfn = "def wop_hash(s: str) -> long {\n    let h = 2166136261;\n"
        + "    for i in 0..len(s) { h = ((h ^ s[i]) * 16777619) & 4294967295; };\n"
        + "    h\n};\n";
    let lookup = "def wop_code(n: str) -> [long] {\n"
        + "    let h = wop_hash(n) & " + tostring(hslots - 1) + ";\n"
        + "    let step = 0;\n"
        + "    while (step < " + tostring(hslots) + ") {\n"
        + "        let e = WOP_HASH[h];\n"
        + "        if (e == 0) { return WOP_NONE; };\n"
        + "        if (WOP_NAMES[e - 1] == n) { return WOP_CODES[e - 1]; };\n"
        + "        h = (h + 1) & " + tostring(hslots - 1) + ";\n"
        + "        step++;\n"
        + "    };\n"
        + "    WOP_NONE\n};\n";
    out + names + codes + sl + "const WOP_NONE: [long] = [];\n" + hashfn + lookup +
        imms + "    0\n};\n" +
        "def wop_known(n: str) -> bool { len(wop_code(n)) > 0 };\n" +
        "def wop_count() -> long { " + tostring(n) + " };\n"
}#