// Fixed instruction sequences. Fields not written by a form stay zero.
#{
    let recipes = [
        "emit_load_slot|off: long|MOV_D_R R_RBP -1 1 off -1 R_RAX 64",
        "emit_store_slot|off: long|MOV_R_D R_RAX 64 R_RBP -1 1 off -1",
        "emit_pop_left||MOV_R_R R_RAX 64 R_RCX 64;POP_R R_RAX 64",
        "emit_push_slot|off: long|MOV_D_R R_RBP -1 1 off -1 R_RAX 64;PUSH_R R_RAX 64",
        "emit_push_imm|value: long|MOV_I_R value R_RAX 64;PUSH_R R_RAX 64",
        "emit_zero_slot|off: long|XOR_R_R R_RAX 32 R_RAX 32;MOV_R_D R_RAX 64 R_RBP -1 1 off -1",
        "emit_loop_next|off: long, label: long|INC_D R_RBP -1 1 off -1;JMP_L label",
        "emit_slot_count|off: long|MOV_D_R R_RBP -1 1 off -1 R_RDX 64;MOV_0_R R_RDX -1 1 0 -1 R_RCX 64",
        "emit_slot_bound|off: long, label: long|MOV_D_R R_RBP -1 1 off -1 R_RAX 64;CMP_R_R R_RCX 64 R_RAX 64;JGE_L label",
        "emit_jz|label: long|TEST_R_R R_RAX 64 R_RAX 64;JZ_L label",
        "emit_jnz|label: long|TEST_R_R R_RAX 64 R_RAX 64;JNZ_L label",
        "emit_bool||TEST_R_R R_RAX 64 R_RAX 64;SETNE_R R_RAX 8;MOVZBQ_R_R R_RAX 8 R_RAX 64",
    ];
    let out = "";
    foreach (recipe in recipes) {
        let parts = recipe.split("|");
        out += "def " + parts[0] + "(st: EmitSt" + (parts[1] == "" ? "" : ", " + parts[1]) + ") -> EmitSt {\n";
        foreach (op in parts[2].split(";")) {
            let words = op.split(" ");
            let args = "insn.F_" + words[0];
            for i in 1..8 {
                let arg = i < len(words) ? words[i] : "0";
                if (arg[0:2] == "R_") { arg = "insn." + arg; };
                args += ", " + arg;
            };
            out += "st = emit_insn(st, " + args + ");\n";
        };
        out += "st };\n";
    };
    out
}#
