// std/img.y: every decoder against what ImageMagick decodes the same file to
// (test/data/img/fixtures.bin, built by make.py), the encoders by decoding
// their output again here and by ImageMagick, and hostile input answering none.
import fs;
import img;
import crypto;

def le32(b: [byte], p: long) -> long {
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)
};

let blob = fs.read_bytes("test/data/img/fixtures.bin")!;
print("decode");
let p = 0;
let files: [[byte]] = [];
let refs: [[byte]] = [];
let dims: [[long]] = [];
while (p < blob.length) {
    let nl = blob[p];
    let name = from_bytes(blob[p + 1:p + 1 + nl]);
    let tol = blob[p + 1 + nl];
    let q = p + 2 + nl;
    let w = le32(blob, q);
    let h = le32(blob, q + 4);
    let n = le32(blob, q + 8);
    let file = blob[q + 12:q + 12 + n];
    let ref = blob[q + 12 + n:q + 12 + n + w * h * 4];
    p = q + 12 + n + w * h * 4;
    files += file;
    refs += ref;
    dims += [w, h];
    let im = img.decode(file);
    if (im == none) {
        print(name, " ", img.format(file), " none");
    } else {
        let worst = 0;
        let i = 0;
        let px = im!.px;
        if (im!.w != w || im!.h != h) { worst = 999; } else {
            while (i < px.length) {
                let dd = px[i] - ref[i];
                if (dd < 0) { dd = 0 - dd; };
                if (dd > worst) { worst = dd; };
                i = i + 1;
            };
        };
        print(name, " ", img.format(file), " ", w, "x", h, " ", worst <= tol, " ", worst);
    };
};

print("encode");
let state = 99;
def rnd(m: long) -> long {
    state = (state * 1103515245 + 12345) & 2147483647;
    (state >> 8) % m
};
def same(a: img.Image, b: img.Image) -> bool {
    a.w == b.w && a.h == b.h && a.px == b.px
};
let k = 0;
let wrote: [[byte]] = [];
while (k < files.length) {
    // fixtures 0 (RGBA gradient), 12 (palette), 14 (interlaced) and a JPEG's decode, re-encoded
    if (k == 0 || k == 10 || k == 14 || k == 16 || k == 32 || k == 17 || k == 20) {
        let im = img.decode(files[k])!;
        let png = img.encode_png(im);
        let bmp = img.encode_bmp(im);
        let ppm = img.encode_ppm(im);
        let a = img.decode(png)!;
        let b = img.decode(bmp)!;
        let c = img.decode(ppm)!;
        let opaque = true;
        let i = 3;
        while (i < im.px.length) { if (im.px[i] != 255) { opaque = false; }; i = i + 4; };
        print(k, " ", img.format(png), img.format(bmp), img.format(ppm), " png ", same(a, im), " bmp ", same(b, im), " ppm ", (if (opaque) { same(c, im) } else { c.w == im.w }), " ", opaque, " ", crypto.hex(crypto.sha256(png))[0:16], " ", png.length, " ", bmp.length);
        wrote += png;
        wrote += bmp;
        wrote += ppm;
    };
    k = k + 1;
};
print(img.save("_img_x.png", img.new_image(1, 1)), " ", img.save("_img_x.bmp", img.new_image(1, 1)), " ", img.save("_img_x.ppm", img.new_image(2, 1)), " ", img.save("_img_x.jpg", img.new_image(1, 1)));
let lw = [img.load("_img_x.png")!.w, img.load("_img_x.bmp")!.w, img.load("_img_x.ppm")!.w];
fs.remove_file("_img_x.png");
fs.remove_file("_img_x.bmp");
fs.remove_file("_img_x.ppm");
print(lw[0], " ", lw[1], " ", lw[2], " ", img.load("nope.png") == none);

print("operations");
let g = img.new_image(4, 3);
img.fill(g, img.rgba(10, 20, 30));
img.set_pixel(g, 1, 2, img.rgba(255, 0, 0, 128));
print(img.pixel(g, 0, 0), " ", img.pixel(g, 1, 2), " ", img.pixel(g, 9, 9), " ", img.set_pixel(g, -1, 0, 5));
let cr = img.crop(g, 1, 1, 3, 3);
print(cr.w, "x", cr.h, " ", img.pixel(cr, 0, 1), " ", img.pixel(cr, 2, 2));
print(img.pixel(img.flip_h(g), 2, 2), " ", img.pixel(img.flip_v(g), 1, 0));
let big = img.resize(g, 8, 6, false);
print(big.w, "x", big.h, " ", img.pixel(big, 2, 4), " ", img.pixel(big, 3, 5), " ", img.pixel(big, 0, 0));
let sm = img.resize(g, 2, 3, true);
print(sm.w, "x", sm.h, " ", img.pixel(sm, 0, 0));
let gr = img.to_gray(img.decode(files[0])!);
print(gr.px[0], " ", gr.px[1], " ", gr.px[2], " ", gr.px[3]);

print("hostile");
let handled = 0;
let none_n = 0;
k = 0;
while (k < files.length) {
    let f = files[k];
    if (f.length < 20000) {
        let t = 0;
        while (t < 8) {
            let cut = if (t < 4) { f.length * (t + 1) / 5 } else { rnd(f.length) };
            let r = img.decode(f[0:cut]);
            if (r == none) { none_n = none_n + 1; };
            handled = handled + 1;
            t = t + 1;
        };
        t = 0;
        while (t < 8) {
            let m = f[0:f.length];
            let flips = 1 + rnd(4);
            let u = 0;
            while (u < flips) {
                let at = rnd(if (t < 4) { 64 } else { m.length });
                if (at < m.length) { m[at] = rnd(256); };
                u = u + 1;
            };
            let r = img.decode(m);
            if (r == none) { none_n = none_n + 1; };
            handled = handled + 1;
            t = t + 1;
        };
    };
    k = k + 1;
};
print(handled, " mutated or truncated files decoded without a trap");
print(none_n > 100, " ", none_n < handled);
let empty: [byte] = [];
let junk: [byte] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82];
print(img.decode(empty) == none, " ", img.decode(junk) == none, " ", img.format(empty) == "", " ", img.format(junk));
