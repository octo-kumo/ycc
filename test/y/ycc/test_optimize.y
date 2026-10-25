import wintgt from "../../../src/y/target.y";
import tags from "../../../src/y/tags.y";
import wiretest from "../../../src/y/native.y";
import optpass from "../../../src/y/optimize.y";
import wir from "../../../src/y/ir.y";

def require(ok: bool, what: str) -> void {
    if (!ok) { print("optimization: " + what); exit(1); };
};

let loc = [wir.IR_LOC, 1, 42, 0, 0, 0, 0, 0];
let label = [wir.IR_LABEL, 17, 0, 0, 0, 0, 0, 0];
let ret = [wir.F_RET, 0, 0, 0, 0, 0, 0, 0];
let move = [wir.F_MOV_R_R, wir.R_RAX, 64, wir.R_RAX, 64, 0, 0, 0];
let move32 = [wir.F_MOV_R_R, wir.R_RAX, 32, wir.R_RAX, 32, 0, 0, 0];
let jump = [wir.F_JMP_L, 17, 0, 0, 0, 0, 0, 0];
let imm = [wir.F_MOV_I_R, 42, wir.R_RAX, 64, 0, 0, 0, 0];
let zero = [wir.F_MOV_I_R, 0, wir.R_RAX, 64, 0, 0, 0, 0];
let cmp = [wir.F_CMP_I_R, 3, wir.R_RAX, 64, 0, 0, 0, 0];
let jz = [wir.F_JZ_L, 17, 0, 0, 0, 0, 0, 0];
let raw = [wir.IR_TEXT, 0, 0, 0, 0, 0, 0, 0];
let tail = [wir.F_MOV_R_R, wir.R_RBP, 64, wir.R_RSP, 64, 0, 0, 0,
    wir.F_POP_R, wir.R_RBP, 64, 0, 0, 0, 0, 0] + ret;
foreach (mode in ["size", "speed"]) {
    require(optpass.optimize(move + ret, mode) == ret, "remove 64-bit self move");
    require(optpass.optimize(move32 + ret, mode) == move32 + ret, "32-bit move zero-extends");
    require(optpass.optimize(jump + loc + label + ret, mode) == loc + label + ret, "fallthrough across locations");
    require(optpass.optimize(jump + imm + label + ret, mode) == label + ret, "dead code then fallthrough");
    require(optpass.optimize(ret + imm + raw + ret, mode) == ret + raw + ret, "raw text is a barrier");
    let z = optpass.optimize(zero + loc + cmp + ret, mode);
    require(z[0] == wir.F_XOR_R_R && z[2] == 32 && z[4] == 32, "shared zero idiom");
    require(z[8:] == loc + cmp + ret, "zero idiom retains locations");
    let flags = optpass.optimize(cmp + zero + jz + ret, mode);
    require(flags[8] != wir.F_XOR_R_R, "zero load preserves live flags");
    let barrier = optpass.optimize(zero + label + cmp + ret, mode);
    require(barrier[0] != wir.F_XOR_R_R, "label is a flag-liveness barrier");
};
require(optpass.optimize(imm + ret, "speed") == imm + ret, "speed retains register load");
let small = optpass.optimize(imm + ret, "size");
require(small[0] == wir.F_PUSH_I && small[1] == 42 && small[8] == wir.F_POP_R, "compact size load");
foreach (value in [-129, -128, 127, 128, -2147483648, 4294967295]) {
    let load = [wir.F_MOV_I_R, value, wir.R_R10, 64, 0, 0, 0, 0];
    let out = optpass.optimize(load + ret, "size");
    require((out[0] == wir.F_PUSH_I) == (value >= -128 && value <= 127), "signed immediate boundary");
};
let stack = [wir.F_MOV_I_R, 0, wir.R_RSP, 64, 0, 0, 0, 0];
require(optpass.optimize(stack + ret, "size") == stack + ret, "never push/pop into rsp");
let early = jump + [wir.IR_LABEL, 18, 0, 0, 0, 0, 0, 0] + imm + label + tail;
require(optpass.optimize(early, "size")[0] == wir.F_JMP_L, "size shares return");
require(optpass.optimize(early, "speed")[0:24] == tail, "speed duplicates return");
let aliased = early[0:len(early) - 24] + loc + [wir.IR_LABEL, 19, 0, 0, 0, 0, 0, 0] + tail;
require(optpass.optimize(aliased, "speed")[0:24] == tail, "return label aliases and locations");
let ret_args = [wir.F_RET_I, 24, 0, 0, 0, 0, 0, 0];
let args_tail = tail[0:16] + ret_args;
let args_early = early[0:len(early) - 8] + ret_args;
require(optpass.optimize(args_early, "speed")[0:24] == args_tail, "callee stack cleanup preserved");
print("optimizations: OK");
