// tools/keyserver/keygen.y -- create the keyserver's RSA server key and its
// public pin. Needs `openssl` in PATH. Writes PREFIX.key (modulus and private
// exponent) and PREFIX.pub (modulus and public exponent), both hex lines.
import fs;
import exec;
import crypto;

def field(lines: [str], name: str) -> str {
    let out = "";
    let on = false;
    foreach (l in lines) {
        if (l.starts_with(name + ":")) {
            on = true;
            out += l[name.length + 1:].trim();
        } else if (on) {
            if (len(l) > 0 && l[0] == ' ' && l.trim() != "") { out += l.trim(); }
            else { break; };
        };
    };
    out.replace(":", "")
};

def main() -> long {
    let a = argv();
    if (len(a) < 2) { eputs("usage: keygen PREFIX [BITS]\n"); return 1; };
    let bits = if (len(a) >= 3) { a[2] } else { "2048" };
    let tag = tostring(syscall(39)) + "-" + tostring(clock_us());
    let pem = "/tmp/ks-key-" + tag + ".pem";
    if (exec("openssl genrsa -out " + pem + " " + bits + " >/dev/null 2>&1") != 0) {
        eputs("keygen: openssl genrsa failed\n"); return 1;
    };
    let txt = exec_capture("openssl rsa -in " + pem + " -noout -text 2>/dev/null");
    fs.remove_file(pem);
    let lines = split(txt, "\n");
    let n = field(lines, "modulus");
    let d = field(lines, "privateExponent");
    let e = field(lines, "publicExponent");
    if (n.starts_with("00")) { n = n[2:]; };
    if (d.starts_with("00")) { d = d[2:]; };
    let sp = e.index_of(" ");
    if (sp > 0) {
        let dec = tolong(e[0:sp]);
        if (dec == none) { eputs("keygen: bad public exponent\n"); return 1; };
        let nb = 1;
        while ((dec! >> (8 * nb)) != 0) { nb += 1; };
        e = crypto.hex(crypto.be_bytes(dec!, nb));
    };
    if (len(n) < 512 || len(d) < 512 || len(e) == 0) {
        eputs("keygen: could not parse the RSA key\n"); return 1;
    };
    if (!fs.write_file(a[1] + ".key", n + "\n" + d + "\n")
        || !fs.write_file(a[1] + ".pub", n + "\n" + e + "\n")) {
        eputs("keygen: cannot write the key files\n"); return 1;
    };
    print("wrote " + a[1] + ".key and " + a[1] + ".pub");
    0
};
let r = main();
exit(r);
