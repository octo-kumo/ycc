// Wire compatibility and round-trips across every instruction form.
import wintgt from "../../../src/y/target.y";
import tags from "../../../src/y/tags.y";
import wiretest from "../../../src/y/native.y";
import wir from "../../../src/y/ir.y";
import lab from "../../../src/y/labels.y";

def require(ok: bool, what: str) {
    if (!ok) { print("IR wire: " + what); exit(1); };
};

def octets(xs: [long]) -> str {
    let data: [byte] = [];
    foreach (v in xs) { data += v; };
    from_bytes(data)
};

let word_cases = [
    { value: 0, data: [0] }, { value: 125, data: [125] },
    { value: 126, data: [126, 126, 0] }, { value: 65535, data: [126, 255, 255] },
    { value: -1, data: [127, 255, 255] }, { value: -65535, data: [127, 1, 0] },
    { value: 65536, data: [255, 0, 0, 1, 0, 0, 0, 0, 0] },
    { value: -65536, data: [255, 0, 0, 255, 255, 255, 255, 255, 255] },
    { value: 9223372036854775807, data: [255, 255, 255, 255, 255, 255, 255, 255, 127] },
    { value: -9223372036854775807 - 1, data: [255, 0, 0, 0, 0, 0, 0, 0, 128] },
];
foreach (c in word_cases) {
    let expected = bytes(octets(c.data));
    let packed = join(wiretest.pack_word([], c.value), "");
    require(bytes(packed) == expected, "numeric encoding " + tostring(c.value));
    require(wiretest.unpack_word(expected, 0) == c.value, "numeric decoding");
    require(wiretest.word_w(expected, 0) == len(expected), "numeric width");
};

let foo = lab.lbl_new("foo");
let bar = lab.lbl_new("bar");
let samples = [
    { ir: [wir.F_CALL_L, foo, 0, 0, 0, 0, 0, 0], tail: octets([1, 3]) + "foo", refs: ["foo"] },
    { ir: [wir.F_MOV_X_R, foo, bar, 0, 64, 0, 0, 0], tail: octets([1, 3]) + "foo" + octets([1, 3]) + "bar" + octets([0, 64]), refs: ["foo", "bar"] },
    { ir: [wir.F_LEA_P_R, -1, -1, 1, 0, foo, 0, 64], tail: octets([127, 255, 255, 127, 255, 255, 1, 0, 1, 3]) + "foo" + octets([0, 64]), refs: ["foo"] },
    { ir: [wir.IR_LABEL, bar, 0, 0, 0, 0, 0, 0], tail: octets([1, 3]) + "bar", refs: [] },
    { ir: [wir.IR_LOC, 1, 126, 0, 0, 0, 0, 0], tail: octets([1, 126, 126, 0]), refs: [] },
    { ir: [wir.IR_TEXT, 125, 0, 0, 0, 0, 0, 0], tail: octets([125]), refs: [] },
];
foreach (s in samples) {
    let packed = chr(s.ir[0]) + s.tail;
    require(wiretest.pack_ir(s.ir) == packed, "instruction encoding");
    require(wiretest.unpack_body(packed) == s.ir, "instruction decoding");
    require(wiretest.blob_refs(packed) == s.refs, "packed references");
    require(wiretest.ir_refs(s.ir) == s.refs, "decoded references");
};

let all: [long] = [];
for f in 0..wir.ir_nforms() {
    let fields: [long] = [];
    foreach (kind in wir.ir_form(f).kinds) {
        if (kind == wir.O_LBL) { fields += foo; }
        else if (kind == wir.O_DIFF) { fields += [foo, bar]; }
        else if (kind == wir.O_MEM || kind == wir.O_MEM0) { fields += [5, -1, 1, -65536, bar]; }
        else if (kind == wir.O_REG || kind == wir.O_IND) { fields += [0, 64]; }
        else { fields += 65536; };
    };
    all += f;
    for i in 0..7 { all += i < len(fields) ? fields[i] : 0; };
};
let packed = wiretest.pack_ir(all);
require(wiretest.unpack_body(packed) == all, "all forms round-trip");
require(wiretest.blob_refs(packed) == wiretest.ir_refs(all), "all forms reference scan");

let u = wiretest.unit_empty("probe");
u.files = ["f.y"];
u.exports = [{ name: "foo", label: "foo", typ: type_node({ k: K.tlong }) }];
u.dfl = [{ name: "foo", vals: ["n3"] }];
u.init = "init";
u.bodies = [samples[0].ir];
u.btext = [[]];
u.labels = ["foo"];
u.rodata = [["L", "7"]];
u.globals = ["cell"];
u.tys = ["Alias"];
u.fx = ["x"];
let iface = "1:13:foo3:foo1:l1:13:foo1:12:n3";
let call_blob = chr(wir.F_CALL_L) + samples[0].tail;
let unit_blob = "1:13:f.y" + iface + "4:init1:1" + tostring(len(call_blob)) + ":" + call_blob +
    "1:11:01:13:foo1:11:21:L1:71:14:cell1:15:Alias1:11:x";
require(wiretest.pack_unit_fields(u) == unit_blob, "unit wire order");
require(wiretest.unit_iface(u) == iface, "unit interface");
let cur: Cursor = { s: unit_blob, p: 0 };
let decoded = wiretest.unit_read(cur, "probe", true);
require(cur.p == len(unit_blob), "unit cursor");
require(decoded.name == "probe" && decoded.files == u.files, "unit identity");
require(len(decoded.exports) == 1 && decoded.exports[0].name == "foo" &&
    decoded.exports[0].label == "foo" && decoded.exports[0].typ.k == K.tlong, "unit exports");
require(len(decoded.dfl) == 1 && decoded.dfl[0].name == "foo" && decoded.dfl[0].vals == ["n3"], "unit defaults");
require(decoded.blob == [call_blob] && len(decoded.bodies) == 0 && decoded.refs == [["foo"]], "lazy unit bodies");
require(decoded.btext == u.btext && decoded.labels == u.labels && decoded.rodata == u.rodata, "unit code data");
require(decoded.globals == u.globals && decoded.tys == u.tys && decoded.fx == u.fx, "unit metadata");
let unbound = wiretest.unit_read({ s: unit_blob, p: 0 }, "probe", false);
require(unbound.exports[0].typ.k == K.tnone, "unbound export type");
let frame = wiretest.pack_version() + "1:21:a1:x1:b0:";
require(wiretest.pack_plain_frame(frame) == frame, "transcoded frame retains its unit count");
print("IR wire: all forms, label roles and numeric boundaries passed");
