// wasm_link.y — pass 1 over the linked parts, the chunk/case map, the data
// layout and the wasm module assembly for --target=web.
//
// asm.y's parsers are reused (split_ops, parse_operand, asm_directive) so a
// text part and an IR part see exactly the operands and directive bytes the
// ELF path sees.  What this file adds is the classification pass (code labels
// vs text-data labels), the chunker, the token map (S7) and the
// relocated data image (S3/D6).
import we from "./wasm_enc.y";
import wl from "./wasm_lower.y";
import asm from "./asm.y";
import xenc from "./enc64.y";
import lbl from "./labels.y";
import insn from "./ir.y";

type WPass = { items: [WItem], labels: [WLabel], datas: [WData], err: str };
type WChunks = { chunks: [WChunk], err: str };

let wp_items: [WItem] = [];
let wp_labels: [WLabel] = [];
let wp_datas: [WData] = [];
// The .file table the .loc markers number into, 1-based (asm.y's debug_lines
// builds the same list for the ELF writer).
let wp_files: [str] = [];
let wp_sec = 0;
let wp_offs: [long] = [0, 0, 0];
let wp_td = 0;
let wp_err = "";
let wp_pending: [long] = [];
let wp_part = 0;
let wp_lno = 0;
let wp_curlab = "";
let wp_after_data = false;

def wp_fail(msg: str) -> void {
    if (wp_err == "") { wp_err = msg; };
};

def wp_item(kind: str, mn: str, ops: [Operand], name: str, sec: long,
    off: long, size: long, file: long, line: long, where: str) -> WItem {
    { kind: kind, mn: mn, ops: ops, name: name, sec: sec, off: off,
        size: size, file: file, line: line, part: wp_part, where: where }
};

def wp_label(name: str) -> void {
    let off = wp_offs[wp_sec];
    let doff = off;
    if (wp_sec == 0) { doff = wp_td; };
    let at = len(wp_items);
    wp_items += wp_item("lab", "", [], name, wp_sec, off, 0, 0, 0, name);
    wp_labels += { name: name, sec: wp_sec, off: off, doff: doff,
        code: false, entry: false, addr: 0, chunk: -1, kase: -1, at: at,
        data_end: wp_after_data };
    if (wp_sec == 0) { wp_pending += len(wp_labels) - 1; };
    wp_curlab = name;
};

def wp_resolve(code: bool) -> void {
    for i in 0..len(wp_pending) {
        let idx = wp_pending[i];
        let l = wp_labels[idx];
        wp_labels[idx] = { ...l, code: code };
    };
    wp_pending = [];
};

def wp_add_data(sec: long, off: long, bytes: [byte], fix: [Fixup], size: long) -> void {
    if (sec == 0) { wp_resolve(false); };
    if (sec == 2 && len(bytes) > 0) {
        wp_fail("web: data or code in .bss (part " + tostring(wp_part) + ")");
        return;
    };
    wp_datas += { sec: sec, off: off, bytes: bytes, fix: fix, size: size };
    if (sec == 0) { wp_td += size; };
    if (size > 0) { wp_after_data = true; };
};

def wp_ins(mn: str, ops: [Operand], where: str) -> void {
    if (wp_sec == 0) { wp_resolve(true); };
    wp_after_data = false;
    wp_items += wp_item("ins", mn, ops, "", wp_sec, 0, 0, 0, wp_lno, where);
};

def wp_where() -> str {
    if (wp_curlab == "") {
        "part " + tostring(wp_part) + " line " + tostring(wp_lno)
    } else {
        wp_curlab
    }
};

// A directive line through asm.y's own parser, so the bytes and fixups are
// the ELF path's.
def wp_dirline(line: str, lno: long) -> void {
    let r = asm.asm_directive(line, lno, wp_sec, wp_offs);
    if (r.err != "") {
        wp_fail("web: " + r.err + " (part " + tostring(wp_part) + ")");
        return;
    };
    let it = r.item;
    if (r.sec != wp_sec) {
        if (wp_sec == 0 && r.sec != 0) { wp_resolve(false); };
        wp_sec = r.sec;
    };
    if (it.kind == "file") {
        // .file N "path": the name a later .loc's file number means.
        while (len(wp_files) < it.off) { wp_files += "?"; };
        wp_files[it.off - 1] = it.fix[0].lbl;
        return;
    };
    if (it.kind == "loc") {
        // -g line marker: no bytes, a ysrc row at emit time.
        wp_items += wp_item("loc", "", [], "", 0, 0, 0, it.fix[0].off, it.fix[1].off, wp_where());
        return;
    };
    if (it.sec == 0 && len(it.bytes) > 0 && it.kind != "insn") {
        // Bytes in .text are usually a string or a table the program reads as
        // data (the prelude keeps both there).  Bytes that follow an
        // instruction, though, are machine code the runtime embedded because
        // the encoder has no spelling for it: arch/regions.s writes rep stosq
        // as F3 48 AB.  That sequence is lowered here; any other is a clear
        // diagnostic rather than silent data.
        let n = len(wp_items);
        let inline = n > 0 && wp_items[n - 1].kind == "ins"
            && wp_items[n - 1].part == wp_part;
        if (inline) {
            let b = it.bytes;
            if (len(b) == 3 && b[0] == 243 && b[1] == 72 && b[2] == 171) {
                wp_ins("rep_stosq", [], wp_where());
            } else {
                wp_fail("web: raw machine-code bytes in .text cannot be lowered (" + wp_where() + ")");
            };
            return;
        };
    };
    if (it.sec >= 0 && it.kind != "loc" && it.kind != "file") {
        if (it.len > 0 || len(it.bytes) > 0) {
            let bytes = it.bytes;
            if (it.sec != 2 && len(bytes) < it.len) {
                for k in 0..(it.len - len(bytes)) { bytes += 0; };
            };
            let doff = it.off;
            if (it.sec == 0) { doff = wp_td; };
            wp_add_data(it.sec, doff, bytes, it.fix, it.len);
        };
    };
};

def wp_insline(line: str, lno: long) -> void {
    // GNU as source: a '#' starts a comment, so a trailing one on an
    // instruction line (arch/web.s's audio entries have them) is not an
    // operand.
    let hs = index_of(line, "#");
    if (hs >= 0) { line = trim(line[0:hs]); };
    if (line == "") { return; };
    let sp = index_of(line, " ");
    let tab = index_of(line, "\t");
    let cut = sp;
    if (tab >= 0) {
        if (sp < 0) { cut = tab; } else if (tab < sp) { cut = tab; };
    };
    let mn = line;
    let rest = "";
    if (cut >= 0) {
        mn = line[0:cut];
        rest = trim(line[cut + 1:]);
    };
    let ops: [Operand] = [];
    let ok = true;
    if (rest != "") {
        let texts = asm.split_ops(rest);
        let i = 0;
        while (i < len(texts) && ok) {
            let r = asm.parse_operand(texts[i]);
            if (r.ok) { ops += r.op; } else { ok = false; };
            i++;
        };
    };
    if (!ok) {
        wp_fail("web: bad operand in '" + line + "' (part " + tostring(wp_part) + " line " + tostring(lno) + ")");
    } else {
        wp_ins(mn, ops, wp_where());
    };
};

def wp_textline(line: str, lno: long) -> void {
    let t = trim(line);
    if (len(t) == 0 || t[0] == 35) { return; };
    if (t[len(t) - 1] == 58) {
        let nm = trim(t[0:len(t) - 1]);
        if (nm == "") { wp_fail("web: bad label (part " + tostring(wp_part) + " line " + tostring(lno) + ")"); }
        else { wp_label(nm); };
    } else if (t[0] == 46) {
        wp_dirline(t, lno);
    } else {
        let ci = index_of(t, ":");
        if (ci > 0 && index_of(t[0:ci], "%") < 0) {
            let nm = trim(t[0:ci]);
            let rest = trim(t[ci + 1:]);
            if (nm == "" || rest == "") {
                wp_fail("web: bad label (part " + tostring(wp_part) + " line " + tostring(lno) + ")");
            } else {
                wp_label(nm);
                if (rest[0] == 46) { wp_dirline(rest, lno); } else { wp_insline(rest, lno); };
            };
        } else {
            wp_insline(t, lno);
        };
    };
};

def wp_text_part(text: str) -> void {
    let lines = split(text, "\n");
    let li = 0;
    while (li < len(lines) && wp_err == "") {
        wp_lno = li + 1;
        wp_textline(lines[li], li + 1);
        li++;
    };
};

def wp_ir_part(ir: [long], txt: [str], fno: long) -> void {
    if (wp_sec != 0) { wp_resolve(false); wp_sec = 0; };
    let at = 0;
    while (at < len(ir) && wp_err == "") {
        let f = ir[at];
        if (f == insn.IR_LABEL) {
            wp_label(lbl.lname(ir[at + 1]));
        } else if (f == insn.IR_LOC) {
            // -g line marker: the file number carries the part's .file offset
            // (asm.y's asm_ir_loc adds it the same way).
            wp_items += wp_item("loc", "", [], "", 0, 0, 0, ir[at + 1] + fno,
                ir[at + 2], wp_where());
        } else if (f == insn.IR_TEXT) {
            let i = ir[at + 1];
            let line = "";
            if (i >= 0 && i < len(txt)) { line = txt[i]; };
            wp_lno++;
            wp_textline(line, wp_lno);
        } else {
            let fo = insn.ir_form(f);
            let kinds = fo.kinds;
            let ops: [Operand] = [];
            let wp = at + 1;
            for ki in 0..len(kinds) {
                ops += asm.ir_operand(ir, wp, kinds[ki]);
                wp = wp + insn.ir_kind_words(kinds[ki]);
            };
            wp_lno++;
            wp_ins(fo.mn, ops, wp_where());
        };
        at += insn.IR_W;
    };
};

def wasm_pass1(parts: [LinkPart]) -> WPass {
    wp_items = [];
    wp_labels = [];
    wp_datas = [];
    wp_files = [];
    wp_sec = 0;
    wp_offs = [0, 0, 0];
    wp_td = 0;
    wp_err = "";
    wp_pending = [];
    wp_after_data = false;
    wp_part = 0;
    wp_lno = 0;
    wp_curlab = "";
    let pi = 0;
    while (pi < len(parts) && wp_err == "") {
        wp_part = pi;
        wp_lno = 0;
        wp_curlab = "";
        let p = parts[pi];
        if (len(p.text) > 0) { wp_text_part(p.text); }
        else { wp_ir_part(p.ir, p.txt, p.fno); };
        pi++;
    };
    if (wp_err == "") { wp_resolve(false); };
    { items: wp_items, labels: wp_labels, datas: wp_datas, err: wp_err }
};

// ── entry labels, chunks and cases (S4) ─────────────────────────────────
let wc_chunks: [WChunk] = [];
let wc_items: [long] = [];
let wc_cases: [long] = [];
let wc_labels: [[str]] = [];
let wc_part = -1;
let wc_ins_since = 0;
let wc_ins_chunk = 0;
let wc_pending = false;
let wc_last_call = false;
let wc_err = "";
// Whether the chunk being built starts mid-run (a cap split).
let wc_split = false;

const CHUNK_MAX_INSNS = 8192;
const CHUNK_MAX_CASES = 2048;
const CHUNK_MAX_CASE_INSNS = 2048;

def wc_begin() -> void {
    if (len(wc_cases) == 0) {
        wc_cases += 0;
        let e0: [str] = [];
        wc_labels += [e0];
    };
};

def wc_open_case() -> void {
    wc_cases += len(wc_items);
    let e1: [str] = [];
    wc_labels += [e1];
    wc_ins_since = 0;
    wc_pending = false;
};

def wc_close() -> void {
    if (len(wc_items) > 0) {
        if (wc_last_call) {
            wc_cases += len(wc_items);
            let e0: [str] = [];
        wc_labels += [e0];
        };
        wc_chunks += { items: wc_items, cases: wc_cases, labels: wc_labels,
            split_entry: wc_split };
    };
    wc_items = [];
    wc_cases = [];
    wc_labels = [];
    wc_ins_since = 0;
    wc_ins_chunk = 0;
    wc_pending = false;
    wc_last_call = false;
    wc_split = false;
};

def wc_last_uncond(items: [WItem]) -> bool {
    if (len(wc_items) == 0) { return false; };
    let it = items[wc_items[len(wc_items) - 1]];
    if (it.kind != "ins") { return false; };
    it.mn == "jmp" || it.mn == "ret" || it.mn == "ud2" || it.mn == "int3"
};

def wasm_chunks(items: [WItem], labels: [WLabel], lmap: [AsmLabel], emap: [AsmLabel]) -> WChunks {
    wc_chunks = [];
    wc_items = [];
    wc_cases = [];
    wc_labels = [];
    wc_part = -1;
    wc_ins_since = 0;
    wc_ins_chunk = 0;
    wc_pending = false;
    wc_last_call = false;
    wc_err = "";
    let i = 0;
    while (i < len(items) && wc_err == "") {
        let it = items[i];
        if (it.kind == "lab") {
            if (it.sec != 0) { i++; continue; };
            if (it.part != wc_part && len(wc_items) > 0) {
                wc_close();
            };
            wc_part = it.part;
            wc_begin();
            let li = asm.labmap_get(lmap, it.name);
            let is_entry = asm.labmap_get(emap, it.name).sec >= 0;
            let entry_split = is_entry && wc_last_uncond(items);
            let cap_split = wc_ins_chunk >= CHUNK_MAX_INSNS
                || len(wc_cases) >= CHUNK_MAX_CASES;
            let split = entry_split || cap_split;
            if (split) {
                wc_close();
                wc_part = it.part;
                wc_begin();
                // A cap split starts mid-run: its case 0 is fallen into (a
                // branch into it from the previous chunk would make it an
                // external entry again, in wasm_ext).
                if (cap_split && !entry_split) { wc_split = true; };
            };
            if (wc_ins_since > 0) { wc_open_case(); };
            let cnames = wc_labels[len(wc_labels) - 1];
            cnames += it.name;
            wc_labels[len(wc_labels) - 1] = cnames;
            if (li.sec >= 0) {
                let lb = labels[li.off];
                labels[li.off] = { ...lb, chunk: len(wc_chunks), kase: len(wc_cases) - 1 };
            };
            wc_pending = false;
        } else if (it.kind == "loc") {
            // A -g marker rides with the code after it, but never forces a
            // case and never counts against the caps.
            wc_begin();
            if (wc_pending) { wc_open_case(); };
            wc_items += i;
        } else if (it.kind == "ins") {
            if (it.part != wc_part && len(wc_items) > 0) {
                wc_close();
            };
            wc_part = it.part;
            wc_begin();
            if (wc_ins_chunk >= CHUNK_MAX_INSNS) {
                // A cap split inside straight-line code: the next chunk is
                // fallen into, and the flags travel through the globals.
                wc_close();
                wc_part = it.part;
                wc_begin();
                wc_split = true;
            };
            if (wc_pending || wc_ins_since >= CHUNK_MAX_CASE_INSNS) {
                wc_open_case();
            };
            wc_items += i;
            wc_ins_since++;
            wc_ins_chunk++;
            wc_last_call = it.mn == "call" || it.mn == "syscall";
            wc_pending = wc_last_call;
        };
        i++;
    };
    if (wc_err == "") { wc_close(); };
    { chunks: wc_chunks, err: wc_err }
};

// ── the data image (S3/D6) ───────────────────────────────────────────────
type WLayout = {
    td: [byte], ro: [byte], bss: long,
    base_td: long, base_ro: long, base_bss: long,
    data_end: long, heap_lo: long, mem_min: long
};

def wasm_align64(n: long) -> long {
    if (n % 65536 == 0) { n } else { n + (65536 - n % 65536) }
};

def wasm_layout(datas: [WData], stack_hi: long) -> WLayout {
    let td: [byte] = [];
    let ro: [byte] = [];
    let bss = 0;
    for i in 0..len(datas) {
        let d = datas[i];
        if (d.sec == 0) {
            if (len(d.bytes) > 0) { td += d.bytes; };
            for k in 0..(d.size - len(d.bytes)) { td += 0; };
        } else if (d.sec == 1) {
            if (len(d.bytes) > 0) { ro += d.bytes; };
            for k in 0..(d.size - len(d.bytes)) { ro += 0; };
        } else if (d.sec == 2) {
            bss += d.size;
        };
    };
    let base_td = stack_hi;
    let base_ro = base_td + len(td);
    let base_bss = base_ro + len(ro);
    let data_end = base_bss + bss;
    let heap_lo = wasm_align64(data_end);
    let mem_min = (data_end + 1048576 + 65535) / 65536;
    { td: td, ro: ro, bss: bss, base_td: base_td, base_ro: base_ro,
        base_bss: base_bss, data_end: data_end, heap_lo: heap_lo,
        mem_min: mem_min }
};

def wlab_data_addr(l: WLabel, lay: WLayout) -> long {
    if (l.sec == 0) { lay.base_td + l.doff }
    else if (l.sec == 1) { lay.base_ro + l.doff }
    else { lay.base_bss + l.doff }
};

// A .quad fixup: a data label is its address, a code label is its token.
type WVal = { ok: bool, v: long, err: str };

def wlab_value(labels: [WLabel], lay: WLayout, name: str) -> WVal {
    let plus = index_of(name, "+");
    let nm = name;
    let extra = 0;
    if (plus > 0) {
        let o = tolong(name[plus + 1:]);
        if (o != none) { nm = name[0:plus]; extra = o!; };
    };
    let hit = -1;
    for i in 0..len(labels) {
        if (labels[i].name == nm) { hit = i; i = len(labels); };
    };
    if (hit < 0) {
        return { ok: false, v: 0, err: "web: undefined label '" + nm + "'" };
    };
    let l = labels[hit];
    if (l.code) {
        if (extra != 0) {
            return { ok: false, v: 0, err: "web: a code address difference has no meaning on --target=web (" + name + ")" };
        };
        return { ok: true, v: wl.wl_token(l.chunk, l.kase), err: "" };
    };
    { ok: true, v: wlab_data_addr(l, lay) + extra, err: "" }
};

def wasm_apply_fix(d: WData, labels: [WLabel], lay: WLayout) -> AsmBytes {
    let out = d.bytes;
    let err = "";
    for i in 0..len(d.fix) {
        if (err != "") { i = len(d.fix); } else {
            let fx = d.fix[i];
            if (fx.kind != "abs64") {
                err = "web: unsupported data fixup '" + fx.kind + "'";
            } else {
                let v = wlab_value(labels, lay, fx.lbl);
                if (!v.ok) { err = v.err; }
                else {
                    let off = fx.off;
                    for k in 0..8 { out[off + k] = (v.v >>> (8 * k)) & 255; };
                };
            };
        };
    };
    { bytes: out, err: err }
};

// ── external entry cases (S6) ────────────────────────────────────────────
// A case that can be entered other than by falling into it or by a branch
// from inside the chunk: case 0, a call return point, the target of a call or
// of a branch from another chunk, and an address-taken label.  Flags live
// into one of these is the S6 compile error; the lowering raises it.
def wl_mark_label(ext: [[long]], labels: [WLabel], lmap: [AsmLabel], name: str) -> void {
    let li = asm.labmap_get(lmap, name);
    if (li.sec < 0) { return; };
    let l = labels[li.off];
    if (!l.code || l.chunk < 0) { return; };
    if (l.chunk >= len(ext)) { return; };
    let e = ext[l.chunk];
    if (l.kase >= 0 && l.kase < len(e)) {
        e[l.kase] = 1;
        ext[l.chunk] = e;
    };
};

def wasm_ext(chunks: [WChunk], items: [WItem], labels: [WLabel],
    lmap: [AsmLabel], emap: [AsmLabel]) -> [[long]] {
    let ext: [[long]] = [];
    for ci in 0..len(chunks) {
        let e: [long] = [];
        for k in 0..len(chunks[ci].cases) { e += 0; };
        // Case 0 is an entry unless the chunk is a cap split of one run: that
        // case is only fallen into, so the flags can be handed on.
        if (len(e) > 0 && !chunks[ci].split_entry) { e[0] = 1; };
        ext += [e];
    };
    for ci in 0..len(chunks) {
        // A chunk-local item position -> its case, for the return points
        // (a chunk's cases are positions in its own item list).
        let nlocal = len(chunks[ci].items);
        let cat: [long] = [];
        for q in 0..(nlocal + 1) { cat += -1; };
        for k in 0..len(chunks[ci].cases) {
            let at0 = chunks[ci].cases[k];
            if (at0 >= 0 && at0 <= nlocal) { cat[at0] = k; };
        };
        for p in 0..nlocal {
            let it = items[chunks[ci].items[p]];
            if (it.kind != "ins") { continue; };
            let jc = wl_jcc_cc(it.mn);
            let is_branch = jc.ok || it.mn == "jmp";
            for k in 0..len(it.ops) {
                let op = it.ops[k];
                if (op.k == K.lbl) {
                    if (it.mn == "call" || is_branch) {
                        wl_mark_label(ext, labels, lmap, op.name);
                    };
                    if (asm.labmap_get(emap, op.name).sec >= 0) {
                        wl_mark_label(ext, labels, lmap, op.name);
                    };
                } else if (op.k == K.mem && op.rip) {
                    if (asm.labmap_get(emap, op.lbl).sec >= 0) {
                        wl_mark_label(ext, labels, lmap, op.lbl);
                    };
                };
            };
            if (it.mn == "call") {
                // The token a call pushes names the case after it: a return
                // point, where the flags are dead (S6/F14).
                if (p + 1 < len(cat) && cat[p + 1] >= 0) {
                    let e = ext[ci];
                    e[cat[p + 1]] = 1;
                    ext[ci] = e;
                };
            };
        };
    };
    ext
};

// ── module assembly ──────────────────────────────────────────────────────
def wl_longs(b: [byte]) -> [long] {
    let out: [long] = [];
    for i in 0..len(b) { out += b[i]; };
    out
};

def wl_bytes(l: [long]) -> [byte] {
    let out: [byte] = [];
    for i in 0..len(l) { out += l[i] & 255; };
    out
};

def wl_has_label(labels: [WLabel], name: str) -> bool {
    let hit = false;
    for i in 0..len(labels) {
        if (labels[i].name == name) { hit = true; i = len(labels); };
    };
    hit
};

def wasm_fail(msg: str) -> AsmOutI {
    let times: [Timing] = [];
    { ok: false, bytes: [], error: msg, times: times, items: 0 }
};

def wasm_chunk_name(ch: WChunk, i: long) -> str {
    let k = 0;
    while (k < len(ch.labels)) {
        if (len(ch.labels[k]) > 0) { return ch.labels[k][0]; };
        k++;
    };
    "chunk" + tostring(i)
};

def wasm_assemble(parts: [LinkPart], debug: bool, stack_hi: long, checked: bool) -> AsmOutI {
    let ps = wasm_pass1(parts);
    if (ps.err != "") { return wasm_fail(ps.err); };
    let items = ps.items;
    let labels = ps.labels;
    let datas = ps.datas;
    // bss: y_bss_lo/y_bss_hi are the writer's labels (asm_link defines them)
    let bss = 0;
    for i in 0..len(datas) {
        if (datas[i].sec == 2) { bss += datas[i].size; };
    };
    if (bss > 0) {
        labels += { name: "y_bss_lo", sec: 2, off: 0, doff: 0, code: false,
            entry: false, addr: 0, chunk: -1, kase: -1, at: 0, data_end: false };
        labels += { name: "y_bss_hi", sec: 2, off: bss, doff: bss, code: false,
            entry: false, addr: 0, chunk: -1, kase: -1, at: 0, data_end: false };
    };
    let lm = asm.labmap_new(len(labels) * 2 + 16);
    for i in 0..len(labels) {
        lm = asm.labmap_put(lm, labels[i].name, 0, i).map;
    };
    let lmap = lm;
    // entry-forcing labels: call targets, address-taken code, _start
    let em = asm.labmap_new(len(labels) * 2 + 16);
    let emap = em;
    let scan = 0;
    while (scan < len(items) && wp_err == "") {
        let it = items[scan];
        if (it.kind == "ins") {
            let k = 0;
            while (k < len(it.ops)) {
                let op = it.ops[k];
                if (op.k == K.lbl) {
                    let li = asm.labmap_get(lmap, op.name);
                    if (li.sec >= 0 && labels[li.off].code) {
                        // S4: an entry is forced by a call target, an
                        // address-taken label (lea/.quad, below) and _start.
                        // A branch target is not an entry: it stays a case
                        // inside its chunk.
                        if (it.mn == "call") { emap = asm.labmap_put(emap, op.name, 0, 1).map; };
                    };
                } else if (op.k == K.mem && op.rip) {
                    let li = asm.labmap_get(lmap, op.lbl);
                    if (li.sec >= 0 && labels[li.off].code) {
                        if (it.mn == "lea") {
                            emap = asm.labmap_put(emap, op.lbl, 0, 1).map;
                        } else if (labels[li.off].data_end) {
                            let lm2 = labels[li.off];
                            labels[li.off] = { ...lm2, code: false };
                        } else {
                            wp_fail("web: " + op.lbl + " is code and is read as data at " + it.where);
                        };
                    };
                } else if (op.k == K.diff) {
                    let a = asm.labmap_get(lmap, op.a);
                    let b = asm.labmap_get(lmap, op.b);
                    if (a.sec >= 0 && labels[a.off].code && !labels[a.off].data_end) {
                        wp_fail("web: a code address difference (" + op.a + "-" + op.b + ") has no meaning on --target=web");
                    };
                    if (b.sec >= 0 && labels[b.off].code && !labels[b.off].data_end) {
                        wp_fail("web: a code address difference (" + op.a + "-" + op.b + ") has no meaning on --target=web");
                    };
                    if (a.sec >= 0 && labels[a.off].data_end) {
                        let la = labels[a.off];
                        labels[a.off] = { ...la, code: false };
                    };
                    if (b.sec >= 0 && labels[b.off].data_end) {
                        let lb = labels[b.off];
                        labels[b.off] = { ...lb, code: false };
                    };
                };
                k++;
            };
        };
        scan++;
    };
    if (wp_err != "") { return wasm_fail(wp_err); };
    // address-taken code labels in .quad data
    for i in 0..len(datas) {
        let d = datas[i];
        for k in 0..len(d.fix) {
            let li = asm.labmap_get(lmap, d.fix[k].lbl);
            if (li.sec >= 0 && labels[li.off].code) {
                emap = asm.labmap_put(emap, d.fix[k].lbl, 0, 1).map;
            };
        };
    };
    let ck = wasm_chunks(items, labels, lmap, emap);
    if (ck.err != "") { return wasm_fail(ck.err); };
    let chunks = ck.chunks;
    let start_i = asm.labmap_get(lmap, "_start");
    if (start_i.sec < 0 || !labels[start_i.off].code) {
        return wasm_fail("web: no _start label (empty program?)");
    };
    let lay = wasm_layout(datas, stack_hi);
    for i in 0..len(labels) {
        let l = labels[i];
        if (!l.code) {
            labels[i] = { ...l, addr: wlab_data_addr(l, lay) };
        };
    };
    // tokens must fit S7's fields
    for i in 0..len(chunks) {
        if (i >= 1048576) { return wasm_fail("web: more than 2^20 chunks"); };
        if (len(chunks[i].cases) >= 1048576) { return wasm_fail("web: more than 2^20 cases in a chunk"); };
    };
    let st = labels[start_i.off];
    if (st.chunk < 0) { return wasm_fail("web: _start label was not placed in a chunk (internal)"); };
    let entry = wl.wl_token(st.chunk, st.kase);
    let exts = wasm_ext(chunks, items, labels, lmap, emap);
    // ── the module ──
    we.we_reset();
    we.we_set_table(len(chunks));
    we.we_set_memory(lay.mem_min, 65536);
    let p7: [long] = [];
    for i in 0..7 { p7 += we.VT_I64; };
    let sys_ty = we.we_type(p7, [we.VT_I64]);
    let trap_ty = we.we_type([we.VT_I32], []);
    let chunk_ty = we.we_type([we.VT_I32], []);
    let i64v_ty = we.we_type([we.VT_I64], []);
    let i32v_ty = we.we_type([we.VT_I32], []);
    let void_i32_ty = we.we_type([], [we.VT_I32]);
    let sys_fi = we.we_import_func("y", "sys", sys_ty);
    let trap_fi = we.we_import_func("y", "trap", trap_ty);
    // globals, in wasm_lower's order
    for i in 0..16 { we.we_global_i64(0); };
    for i in 0..16 { we.we_global_f64(0); };
    we.we_global_i64(0);   // fs
    we.we_global_i32(0);   // fop
    we.we_global_i32(0);   // fsz
    we.we_global_i64(0);   // fa
    we.we_global_i64(0);   // fb
    we.we_global_i64(0);   // fr
    we.we_global_f64(0);   // fx
    we.we_global_f64(0);   // fy
    we.we_global_i32(0);   // fcf
    we.we_global_i64(0);   // pc
    we.we_global_i32(0);   // why
    we.we_global_i32(0);   // fuel
    we.we_global_i64(0);   // q
    we.we_global_i64(0);   // rm
    let p9: [long] = [we.VT_I32, we.VT_I32, we.VT_I32, we.VT_I64, we.VT_I64,
        we.VT_I64, we.VT_F64, we.VT_F64, we.VT_I32];
    let cond_ty = we.we_type(p9, [we.VT_I32]);
    let div_ty = we.we_type([we.VT_I64, we.VT_I64, we.VT_I64], []);
    let chunk_fi0 = 2;
    let chunk_fis: [long] = [];
    for i in 0..len(chunks) { chunk_fis += we.we_func(chunk_ty); };
    let cond_fi = we.we_func(cond_ty);
    let divs_fi = we.we_func(div_ty);
    let divu_fi = we.we_func(div_ty);
    let resume_fi = we.we_func(i64v_ty);
    let save_fi = we.we_func(i32v_ty);
    let load_fi = we.we_func(i32v_ty);
    let fuel_fi = we.we_func(i32v_ty);
    let why_fi = we.we_func(void_i32_ty);
    let setwhy_fi = we.we_func(i32v_ty);
    we.we_export("memory", we.EK_MEMORY, 0);
    we.we_export("resume", we.EK_FUNC, resume_fi);
    we.we_export("ctx_save", we.EK_FUNC, save_fi);
    we.we_export("ctx_load", we.EK_FUNC, load_fi);
    we.we_export("set_fuel", we.EK_FUNC, fuel_fi);
    we.we_export("why", we.EK_FUNC, why_fi);
    we.we_export("set_why", we.EK_FUNC, setwhy_fi);
    // The flag state a chunk's fall-through hands on: a cap split starts
    // mid-run, so its case 0 may need the flags the chunk before it holds.
    // Computed in reverse, since each chunk's tail is the next one's case 0.
    let tails: [long] = [];
    for i in 0..len(chunks) { tails += 0; };
    let ti = len(chunks) - 1;
    while (ti >= 0) {
        let tail = 0;
        if (ti + 1 < len(chunks) && chunks[ti + 1].split_entry) { tail = tails[ti + 1]; };
        let tctx: WCtx = { labels: labels, lmap: lmap, checked: checked,
            chunk: ti, kase: 0, ncases: len(chunks[ti].cases),
            chunk_fi0: chunk_fi0, chunk_ty: chunk_ty,
            trap_fi: trap_fi, sys_fi: sys_fi,
            cond_fi: cond_fi, divs_fi: divs_fi, divu_fi: divu_fi,
            token_base: wl.TOKEN_BASE,
            debug: debug, ext: exts[ti], tail: tail };
        tails[ti] = wl.wl_tail_live(tctx, chunks[ti], items, tail);
        ti--;
    };
    // bodies, in declaration order
    wl.wl_locs_reset();
    let ci = 0;
    while (ci < len(chunks) && wl.wl_err == "") {
        // tails[ci] is this chunk's own case-0 state; the tail into the next
        // chunk is the next chunk's case-0 state when that chunk is a split.
        let etail = 0;
        if (ci + 1 < len(chunks) && chunks[ci + 1].split_entry) { etail = tails[ci + 1]; };
        let ctx: WCtx = { labels: labels, lmap: lmap, checked: checked,
            chunk: ci, kase: 0, ncases: len(chunks[ci].cases),
            chunk_fi0: chunk_fi0, chunk_ty: chunk_ty,
            trap_fi: trap_fi, sys_fi: sys_fi,
            cond_fi: cond_fi, divs_fi: divs_fi, divu_fi: divu_fi,
            token_base: wl.TOKEN_BASE,
            debug: debug, ext: exts[ci], tail: etail };
        let body = wl.wl_chunk_body(ctx, chunks[ci], items,
            if (ci + 1 < len(chunks)) { ci + 1 } else { -1 });
        we.we_code(body);
        ci++;
    };
    if (wl.wl_err != "") { return wasm_fail(wl.wl_err); };
    we.we_code(wl.wl_cond_body());
    we.we_code(wl.wl_divs_body(trap_fi, divu_fi));
    we.we_code(wl.wl_divu_body(trap_fi));
    we.we_code(wl.wl_resume_body(chunk_ty, trap_fi));
    we.we_code(wl.wl_ctx_save_body());
    we.we_code(wl.wl_ctx_load_body());
    we.we_code(wl.wl_set_fuel_body());
    we.we_code(wl.wl_why_body());
    we.we_code(wl.wl_set_why_body());
    // data segments: the whole text-data image, then the whole rodata image
    // (one active segment each: separate segments at one base would overwrite
    // each other)
    let td = lay.td;
    let ro = lay.ro;
    let di = 0;
    while (di < len(datas) && wp_err == "") {
        let d = datas[di];
        if (d.sec == 0 || d.sec == 1) {
            let f = wasm_apply_fix(d, labels, lay);
            if (f.err != "") { wp_fail(f.err); }
            else {
                let dst = if (d.sec == 0) { td } else { ro };
                let k = 0;
                while (k < len(f.bytes) && d.off + k < len(dst)) {
                    dst[d.off + k] = f.bytes[k];
                    k++;
                };
                if (d.sec == 0) { td = dst; } else { ro = dst; };
            };
        };
        di++;
    };
    if (wp_err == "") {
        we.we_data(lay.base_td, td);
        we.we_data(lay.base_ro, ro);
    };
    if (wp_err != "") { return wasm_fail(wp_err); };
    let names: [str] = [];
    for i in 0..len(chunks) { names += wasm_chunk_name(chunks[i], i); };
    // The helper functions, in declaration order after the chunks.
    names += "$cond";
    names += "$div128s";
    names += "$div128u";
    names += "resume";
    names += "ctx_save";
    names += "ctx_load";
    names += "set_fuel";
    names += "why";
    names += "set_why";
    // -g: the ysrc mapping the host turns a wasm frame into file:line with.
    // One line per row: function index, byte offset in the body, file:line.
    if (debug && len(wl.wl_locs()) > 0) {
        let ys = "ysrc=1
";
        foreach (row in wl.wl_locs()) {
            let f = "?";
            if (row.file >= 1 && row.file <= len(wp_files)) { f = wp_files[row.file - 1]; };
            ys += tostring(row.func) + " " + tostring(row.at) + " " + f + ":" + tostring(row.line) + "
";
        };
        we.we_custom("ysrc", ys);
    };
    let threadsv = 0;
    if (wl_has_label(labels, "y_spawn")) { threadsv = 1; };
    let guiv = 0;
    if (wl_has_label(labels, "y_gui_open")) { guiv = 1; };
    let audiov = 0;
    if (wl_has_label(labels, "y_os_audio_open")) { audiov = 1; };
    let yw = "abi=1\n"
        + "stack_lo=0\n"
        + "stack_hi=" + tostring(stack_hi) + "\n"
        + "data_lo=" + tostring(lay.base_td) + "\n"
        + "data_end=" + tostring(lay.data_end) + "\n"
        + "heap_lo=" + tostring(lay.heap_lo) + "\n"
        + "entry=" + tostring(entry) + "\n"
        + "chunks=" + tostring(len(chunks)) + "\n"
        + "threads=" + tostring(threadsv) + "\n"
        + "gui=" + tostring(guiv) + "\n"
        + "audio=" + tostring(audiov) + "\n";
    we.we_custom("yweb", yw);
    let bytes = we.we_finish(chunk_fis, names, debug);
    let times: [Timing] = [];
    { ok: true, bytes: bytes, error: "", times: times, items: len(items) }
};

// ── web-forms: prove every IR form has a web lowering ───────────────────
// ycc --web-forms (a test hook; ytest's web-forms case runs it) lowers one
// synthetic instance of each IR form through the real per-instruction path and
// prints what the lowering said.  A form added to ir_schema.y without a web
// lowering fails here, by name, instead of in a user's compile.
def wl_probe_sse(mn: str) -> bool {
    mn == "movsd" || mn == "addsd" || mn == "subsd" || mn == "mulsd" || mn == "divsd"
    || mn == "sqrtsd" || mn == "ucomisd" || mn == "cvtsi2sd" || mn == "cvttsd2si"
    || mn == "xorpd" || mn == "andpd" || mn == "orpd"
};

def wl_probe_reg(mn: str, i: long) -> str {
    if (mn == "cvtsi2sd") { if (i == 0) { return "%rax"; }; return "%xmm0"; };
    if (mn == "cvttsd2si") { if (i == 0) { return "%xmm0"; }; return "%rax"; };
    if (wl_probe_sse(mn)) { return "%xmm0"; };
    if (mn == "movzbq" || mn == "movsbq" || mn == "movb" || mn == "cmpb" || mn == "testb"
        || mn.starts_with("set")) {
        if (i == 0) { return "%al"; }; return "%rax";
    };
    if (mn == "movzwq" || mn == "movswq" || mn == "movw") {
        if (i == 0) { return "%ax"; }; return "%rax";
    };
    if (mn == "movslq" || mn == "movl" || mn == "bswapl") {
        if (i == 0) { return "%eax"; }; return "%rax";
    };
    if ((mn == "shl" || mn == "sal" || mn == "shr" || mn == "sar") && i == 0) { return "%rcx"; };
    if (mn == "movq") { return "%xmm0"; };
    "%rax"
};

def wl_probe_op(k: long, mn: str, i: long) -> str {
    if (k == insn.O_REG) { return wl_probe_reg(mn, i); }
    else if (k == insn.O_IND) { return "*%rcx"; }
    else if (k == insn.O_IMM) { return "$1"; }
    else if (k == insn.O_LBL) { return "Lc"; }
    else if (k == insn.O_DIFF) { return "$Lp-Lq"; }
    else if (k == insn.O_MEM || k == insn.O_MEM0) { return "8(%rsp)"; }
    else if (k == insn.O_FS) { return "%fs:0"; };
    ""
};

def wl_probe_fi(mn: str, ops: [Operand], where: str) -> WItem {
    { kind: "ins", mn: mn, ops: ops, name: "", sec: 0, off: 0, size: 0,
        file: 0, line: 0, part: 0, where: where }
};

// One probe: a four-label chunk whose only case is the instruction.
def wl_probe_one(mn: str, ops: [Operand], where: str) -> str {
    let labels: [WLabel] = [
        { name: "Lc", sec: 0, off: 0, doff: 0, code: true, entry: true, addr: 0,
            chunk: 0, kase: 0, at: 0, data_end: false },
        { name: "Lend", sec: 0, off: 0, doff: 0, code: true, entry: true, addr: 0,
            chunk: 0, kase: 0, at: 0, data_end: false },
        { name: "Lp", sec: 1, off: 0, doff: 0, code: false, entry: false, addr: 4096,
            chunk: -1, kase: -1, at: 0, data_end: false },
        { name: "Lq", sec: 1, off: 8, doff: 8, code: false, entry: false, addr: 8192,
            chunk: -1, kase: -1, at: 0, data_end: false }
    ];
    let lm = asm.labmap_new(16);
    for i in 0..len(labels) {
        lm = asm.labmap_put(lm, labels[i].name, 0, i).map;
    };
    let items: [WItem] = [wl_probe_fi(mn, ops, where)];
    let cases: [long] = [0];
    let lnames: [[str]] = [["Lc"]];
    let ch: WChunk = { items: [0], cases: cases, labels: lnames, split_entry: false };
    let ctx: WCtx = { labels: labels, lmap: lm, checked: false,
        chunk: 0, kase: 0, ncases: 1, chunk_fi0: 2, chunk_ty: 0,
        trap_fi: 0, sys_fi: 1, cond_fi: 3, divs_fi: 4, divu_fi: 5,
        token_base: wl.TOKEN_BASE, debug: false, ext: [0], tail: 0 };
    wl.wl_probe_reset();
    wl.wl_chunk_body(ctx, ch, items, -1);
    let e = wl.wl_err;
    if (e == "") { "ok" } else { "error: " + e }
};

def wasm_form_probe() -> str {
    let out = "";
    let n = insn.ir_nforms();
    for f in 0..n {
        let fo = insn.ir_form(f);
        let ops: [Operand] = [];
        let ok = true;
        for i in 0..len(fo.kinds) {
            let t = wl_probe_op(fo.kinds[i], fo.mn, i);
            let r = asm.parse_operand(t);
            if (r.ok) { ops += r.op; } else { ok = false; };
        };
        let where = "form " + tostring(f) + " " + fo.mn;
        let res = "bad probe operand";
        if (ok) { res = wl_probe_one(fo.mn, ops, where); };
        out += "form " + tostring(f) + " " + fo.mn + ": " + res + "\n";
    };
    // The S5 set also has text-only mnemonics (no IR form): probe those too.
    foreach (mn in ["xorpd", "andpd", "orpd", "bsr", "bswapq", "bswapl", "xchg", "sqrtsd"]) {
        let ops: [Operand] = [];
        let ok = true;
        if (mn == "bsr") {
            let a = asm.parse_operand("%rax");
            let b = asm.parse_operand("%rbx");
            if (a.ok && b.ok) { ops += a.op; ops += b.op; } else { ok = false; };
        } else if (mn == "bswapq" || mn == "bswapl") {
            let a = asm.parse_operand(if (mn == "bswapq") { "%rax" } else { "%eax" });
            if (a.ok) { ops += a.op; } else { ok = false; };
        } else if (mn == "xchg") {
            let a = asm.parse_operand("%rax");
            let b = asm.parse_operand("8(%rsp)");
            if (a.ok && b.ok) { ops += a.op; ops += b.op; } else { ok = false; };
        } else {
            let a = asm.parse_operand("%xmm0");
            let b = asm.parse_operand("%xmm1");
            if (a.ok && b.ok) { ops += a.op; ops += b.op; } else { ok = false; };
        };
        let where = "text " + mn;
        let res = "bad probe operand";
        if (ok) { res = wl_probe_one(mn, ops, where); };
        out += "text " + mn + ": " + res + "\n";
    };
    out
};

// ── --emit=wat: a debugging listing, not a round-trip format ─────────────
def wat_leb(b: [byte], at0: long) -> { v: long, at: long } {
    let v = 0;
    let shift = 0;
    let at = at0;
    let more = true;
    while (more && at < len(b)) {
        let c = b[at];
        at++;
        v |= (c & 127) << shift;
        shift += 7;
        if ((c & 128) == 0) { more = false; };
    };
    { v: v, at: at }
};

def wat_hex(b: [byte], from: long, to: long) -> str {
    let out = "";
    let at = from;
    while (at < to) {
        let line = "    ";
        let k = 0;
        while (k < 16 && at < to) {
            let c = b[at] & 255;
            let hi = c >> 4;
            let lo = c & 15;
            line = line + chr(if (hi < 10) { 48 + hi } else { 87 + hi });
            line = line + chr(if (lo < 10) { 48 + lo } else { 87 + lo });
            line = line + " ";
            at++;
            k++;
        };
        out += line + "\n";
    };
    out
};

def wasm_wat(b: [byte]) -> str {
    let out = "(module ;; " + tostring(len(b)) + " bytes; a debugging listing, not a round-trip format\n";
    if (len(b) < 8) { return out + ")\n"; };
    let at = 8;
    while (at < len(b)) {
        let id = b[at] & 255;
        at++;
        let sz = wat_leb(b, at);
        at = sz.at;
        let end = at + sz.v;
        if (end > len(b)) { end = len(b); };
        let nm = "";
        if (id == 0) { nm = "custom"; }
        else if (id == 1) { nm = "type"; }
        else if (id == 2) { nm = "import"; }
        else if (id == 3) { nm = "function"; }
        else if (id == 4) { nm = "table"; }
        else if (id == 5) { nm = "memory"; }
        else if (id == 6) { nm = "global"; }
        else if (id == 7) { nm = "export"; }
        else if (id == 9) { nm = "element"; }
        else if (id == 10) { nm = "code"; }
        else if (id == 11) { nm = "data"; }
        else { nm = "?"; };
        out += "  ;; section " + tostring(id) + " (" + nm + ") " + tostring(sz.v) + " bytes\n";
        if (id == 0) {
            let nl = wat_leb(b, at);
            let nend = nl.at + nl.v;
            let cname = "";
            let i = nl.at;
            while (i < nend && i < len(b)) { cname += chr(b[i] & 255); i++; };
            out += "  ;; custom name: " + cname + "\n";
            if (cname == "yweb") {
                let j = nend;
                while (j < end) {
                    let line = "  ;; yweb: ";
                    while (j < end && b[j] != 10) { line += chr(b[j] & 255); j++; };
                    j++;
                    out += line + "\n";
                };
            };
            out += wat_hex(b, nl.at, end);
        } else {
            out += wat_hex(b, at, end);
        };
        at = end;
    };
    out + ")\n"
};


export { wasm_pass1, wasm_layout, wasm_chunks, wasm_assemble, wasm_wat,
    wasm_form_probe };