// wasm_schema.y — the WebAssembly opcodes the web writer uses.
//
// One row per instruction: name|opcode bytes in hex|dynamic immediates.
// wasm_shapes.y expands the rows into constants and wop_code/wop_imm, the
// same split target_schema.y/target_shapes.y and ir_schema.y/ir_forms.y use.
// Fixed immediates belong in the byte column (memory.size is 3f 00); the
// dynamic ones are written by wasm_enc.y and named in the last column:
//
//   u32 s32 s64 f64 memarg bt br_table call call_indirect local global
//
// The set is the web design's operation list plus the couple of operations the
// integer lowering needs (rem_u, rotl).  A mnemonic that is not here is not
// in the W3 lowering either; wasm_lower.y refuses it by name.
const WASM_OPS = [
    "unreachable|00|", "nop|01|", "block|02|bt", "loop|03|bt", "if|04|bt",
    "else|05|", "end|0b|", "br|0c|u32", "br_if|0d|u32",
    "br_table|0e|br_table", "return|0f|", "call|10|call",
    "call_indirect|11|call_indirect", "return_call|12|call",
    "return_call_indirect|13|call_indirect",
    "drop|1a|", "select|1b|",
    "local.get|20|local", "local.set|21|local", "local.tee|22|local",
    "global.get|23|global", "global.set|24|global",
    "i32.load|28|memarg", "i64.load|29|memarg", "f64.load|2b|memarg",
    "i64.load8_s|30|memarg", "i64.load8_u|31|memarg",
    "i64.load16_s|32|memarg", "i64.load16_u|33|memarg",
    "i64.load32_s|34|memarg", "i64.load32_u|35|memarg",
    "i32.store|36|memarg", "i64.store|37|memarg", "f64.store|39|memarg",
    "i64.store8|3c|memarg", "i64.store16|3d|memarg", "i64.store32|3e|memarg",
    "memory.size|3f 00|", "memory.grow|40 00|",
    "i32.const|41|s32", "i64.const|42|s64", "f64.const|44|f64",
    "i32.eqz|45|", "i32.eq|46|", "i32.ne|47|", "i32.lt_s|48|",
    "i32.lt_u|49|", "i32.gt_s|4a|", "i32.gt_u|4b|", "i32.le_s|4c|",
    "i32.le_u|4d|", "i32.ge_s|4e|", "i32.ge_u|4f|",
    "i64.eqz|50|", "i64.eq|51|", "i64.ne|52|", "i64.lt_s|53|",
    "i64.lt_u|54|", "i64.gt_s|55|", "i64.gt_u|56|", "i64.le_s|57|",
    "i64.le_u|58|", "i64.ge_s|59|", "i64.ge_u|5a|",
    "f64.eq|61|", "f64.ne|62|", "f64.lt|63|", "f64.gt|64|",
    "f64.le|65|", "f64.ge|66|",
    "i32.clz|67|", "i32.ctz|68|", "i32.popcnt|69|", "i32.add|6a|",
    "i32.sub|6b|", "i32.mul|6c|", "i32.div_s|6d|", "i32.div_u|6e|",
    "i32.rem_s|6f|", "i32.rem_u|70|", "i32.and|71|", "i32.or|72|",
    "i32.xor|73|", "i32.shl|74|", "i32.shr_s|75|", "i32.shr_u|76|",
    "i32.rotl|77|", "i32.rotr|78|",
    "i64.clz|79|", "i64.ctz|7a|", "i64.popcnt|7b|", "i64.add|7c|",
    "i64.sub|7d|", "i64.mul|7e|", "i64.div_s|7f|", "i64.div_u|80|",
    "i64.rem_s|81|", "i64.rem_u|82|", "i64.and|83|", "i64.or|84|",
    "i64.xor|85|", "i64.shl|86|", "i64.shr_s|87|", "i64.shr_u|88|",
    "i64.rotl|89|", "i64.rotr|8a|",
    "f64.abs|99|", "f64.neg|9a|", "f64.ceil|9b|", "f64.floor|9c|",
    "f64.trunc|9d|", "f64.nearest|9e|", "f64.sqrt|9f|", "f64.add|a0|",
    "f64.sub|a1|", "f64.mul|a2|", "f64.div|a3|", "f64.min|a4|",
    "f64.max|a5|", "f64.copysign|a6|",
    "i32.wrap_i64|a7|", "i32.trunc_f64_s|aa|", "i32.trunc_f64_u|ab|",
    "i64.extend_i32_s|ac|", "i64.extend_i32_u|ad|",
    "i64.trunc_f64_s|b0|", "i64.trunc_f64_u|b1|",
    "f64.convert_i32_s|b7|", "f64.convert_i32_u|b8|",
    "f64.convert_i64_s|b9|", "f64.convert_i64_u|ba|",
    "i64.reinterpret_f64|bd|", "f64.reinterpret_i64|bf|",
    "i32.extend8_s|c0|", "i32.extend16_s|c1|",
    "i64.extend8_s|c2|", "i64.extend16_s|c3|", "i64.extend32_s|c4|",
    "i64.trunc_sat_f64_s|fc 06|", "i64.trunc_sat_f64_u|fc 07|",
];
export { WASM_OPS };
