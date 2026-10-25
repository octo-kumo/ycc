// Form constants and table initialization generated together.
#{
    import forms from "./ir_schema.y";
    let out = "";
    let entries = "";
    let widths = "def ir_kind_words(k: long) -> long {\n";
    for id in 0..len(forms.IR_OPERANDS) {
        let op = forms.IR_OPERANDS[id];
        out += "const O_" + op.name + " = " + tostring(id + 1) + ";\n";
        widths += "if (k == O_" + op.name + ") { return " + tostring(len(op.wire)) + "; };\n";
    };
    for id in 0..len(forms.IR_FORMS) {
        let row = forms.IR_FORMS[id];
        let parts = row.split(" ");
        out += "const F_" + parts[0] + " = " + tostring(id) + ";\n";
        let kinds = "";
        let wire = "";
        for i in 2..len(parts) {
            if (kinds != "") { kinds += ", "; };
            kinds += "O_" + parts[i];
            let found = false;
            foreach (op in forms.IR_OPERANDS) {
                if (op.name == parts[i]) { wire += op.wire; found = true; };
            };
            if (!found) { eputs("unknown operand kind in IR form: " + row); exit(1); };
        };
        if (len(wire) > 7) { eputs("IR form exceeds seven operand fields: " + row); exit(1); };
        entries += "{id: " + tostring(id) + ", mn: \"" + parts[1] + "\", kinds: [" + kinds +
            "], wire: \"" + wire + "\"},\n";
    };
    out + widths + "1 };\n" +
        "type IrForm = { id: long, mn: str, kinds: [long], wire: str };\nlet ir_tab: [IrForm] = [];\nlet ir_ready = false;\ndef ir_init() -> void { ir_tab = [" + entries + "]; ir_ready = true; };\n"
}#
