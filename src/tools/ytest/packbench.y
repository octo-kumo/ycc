// packbench.y -- `ytest pack-bench [BIN]`: what boxing a binary with --pack
// costs, method by method.
//
// This is the experiment `--pack`'s default was chosen by. BIN (default
// ./ycc) is packed with every in-tree method; each row reports the artifact's
// total, its payload and its decompression code (the stub, which travels
// inside the artifact: total = stub + payload + 16), and whether the packed
// program still runs. The external compressors in $PATH are run on the same
// payload as a floor -- they have no in-tree decoder, so they are a reference
// number rather than a shipped option, and the last two columns say so.
import fs;
import yt;

let METHODS = ["store", "lz", "fixed", "dynamic"];
// name, command reading stdin and writing the compressed stream to stdout.
let EXTERNALS = [["gzip -9", "gzip -9 -n -c"], ["xz -9e", "xz -9e -c"],
    ["zstd -19", "zstd -19 -c"], ["brotli -q11", "brotli -q 11 -c"],
    ["bzip2 -9", "bzip2 -9 -c"]];

def pad(s: str, w: long) -> str {
    let r = s;
    while (r.length < w) { r = r + " "; };
    r
};

def padl(s: str, w: long) -> str {
    let r = s;
    while (r.length < w) { r = " " + r; };
    r
};

// The BODY length from the file's YCCPACK2 trailer, or -1.
def body_len(b: [byte]) -> long {
    if (b.length < 16 || from_bytes(b[b.length - 8:b.length]) != "YCCPACK2") { return -1; };
    let v = 0;
    for i in (b.length - 16)..(b.length - 8) {
        let c = b[i];
        if (c < 48 || c > 57) { return -1; };
        v = v * 10 + (c - 48);
    };
    v
};

def pct(part: long, whole: long) -> str {
    if (whole <= 0) { return "-"; };
    let t = (part * 1000) / whole;
    tostring(t / 10) + "." + tostring(t % 10) + "%"
};

def main(av: [str]) -> long {
    let bin = "ycc";
    let verify = true;
    foreach (a in av) {
        if (a == "--no-verify") { verify = false; } else { bin = a; };
    };
    if (!fs.is_file(bin)) {
        eputs("pack-bench: no such file: " + bin + "\n");
        return 1;
    };
    let raw = yt.size(bin);
    let d = yt.tmp_dir("packbench");
    yt.write(d + "/p.y", "print(\"pack-bench\\n\");\n");
    print("pack-bench " + bin + "  " + tostring(raw) + " B\n");
    print(pad("method", 10) + padl("total", 10) + padl("payload", 10) + padl("stub", 8) + padl("of raw", 9) + "  verify\n");
    let ok_dynamic = "";
    foreach (m in METHODS) {
        let out = d + "/" + m;
        let c = yt.cmd([bin, "--pack=" + m, bin, "-o", out]);
        c.merge = true;
        c.timeout = 600 * yt.SCALE;
        let r = yt.run(c);
        if (r.code != 0 || !fs.is_file(out)) {
            print(pad(m, 10) + "failed: " + yt.clip(r.out, 120) + "\n");
        } else {
            let b = yt.bytes_of(out);
            let n = body_len(b);
            let stub = b.length - 16 - n;
            let payload = n - 5;
            let note = "";
            if (verify) {
                let pc = yt.cmd([out, "-o", d + "/p." + m, d + "/p.y"]);
                pc.merge = true;
                pc.timeout = 120 * yt.SCALE;
                let pr = yt.run(pc);
                if (pr.code == 0) {
                    let pc2 = yt.cmd([bin, "-o", d + "/p.plain", d + "/p.y"]);
                    pc2.merge = true;
                    pc2.timeout = 120 * yt.SCALE;
                    let pr2 = yt.run(pc2);
                    note = if (pr2.code == 0 && yt.same_file(d + "/p." + m, d + "/p.plain")) { "same bytes" } else { "DIFFERS" };
                } else {
                    note = "packed compiler failed";
                };
            };
            print(pad(m, 10) + padl(tostring(b.length), 10) + padl(tostring(payload), 10) +
                padl(tostring(stub), 8) + padl(pct(b.length, raw), 9) + "  " + note + "\n");
            if (m == "dynamic") { ok_dynamic = out; };
        };
    };
    // the external floor: compress the same payload (the store artifact's body,
    // which is the driver's automatic plain-pack transcode of BIN)
    let store_out = d + "/store";
    if (fs.is_file(store_out)) {
        let b = yt.bytes_of(store_out);
        let n = body_len(b);
        let payload = b[b.length - 16 - n + 5:b.length - 16];
        let pf = d + "/payload.bin";
        fs.write_bytes(pf, payload);
        print("\nexternal compressors on the same " + tostring(payload.length) +
            " B payload (no in-tree decoder: the floor, not an option)\n");
        foreach (e in EXTERNALS) {
            let prog = e[0].split(" ")[0];
            if (!yt.have(prog)) {
                print(pad(e[0], 12) + "not installed\n");
            } else {
                let sz = yt.num(yt.sh(e[1] + " < " + yt.q(pf) + " | wc -c").out.trim(), -1);
                print(pad(e[0], 12) + padl(tostring(sz), 10) + padl(pct(sz, raw), 9) + "\n");
            };
        };
    };
    // what the packed binary costs to start: the stub decodes the whole
    // payload before it execs it
    if (len(ok_dynamic) > 0) {
        let plain_us = startup_us(bin);
        let pack_us = startup_us(ok_dynamic);
        print("\nstartup: " + bin + " " + tostring(plain_us) + " us/run, packed " +
            tostring(pack_us) + " us/run (" + tostring(pack_us - plain_us) + " us more)\n");
    };
    fs.remove_all(d);
    0
};


// Ten `-h` runs, in microseconds each (the packed binary decodes its payload
// first, so this is what --pack adds to every invocation).
def startup_us(bin: str) -> long {
    let t0 = clock_us();
    let n = 0;
    while (n < 10) {
        let c = yt.cmd([bin, "-h"]);
        c.timeout = 60 * yt.SCALE;
        c.out = "/dev/null";
        yt.run(c);
        n = n + 1;
    };
    (clock_us() - t0) / 10
};

export { main, body_len };
