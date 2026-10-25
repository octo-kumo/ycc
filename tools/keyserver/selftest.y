// tools/keyserver/selftest.y -- the state-file half of the keyserver, without
// sockets. Run it from a scratch directory:
//   ycc --gc=auto tools/keyserver/selftest.y -o selftest && ./selftest
import fs;
import crypto;
import proto;
import store;

let bad = 0;

def check(name: str, ok: bool) -> void {
    if (ok) { print("PASS " + name); }
    else { bad += 1; print("FAIL " + name); };
};

def main() -> long {
    let dir = "ks-selftest-" + tostring(syscall(39));
    fs.make_dir(dir);
    let users = dir + "/users";
    let nf = dir + "/nonces";
    let raw16: [byte] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    let s1 = crypto.hex(raw16);
    fs.write_file(users, "# comment\nbob " + s1 + " lic-1\n\n");
    let u = store.load_users(users);
    check("users: one record", u.ok && len(u.users) == 1 && u.users[0].name == "bob"
        && len(u.users[0].secret) == 16 && u.users[0].license == "lic-1");
    fs.write_file(users, "bob " + s1 + " lic-1\nbob " + s1 + " lic-2\n");
    check("users: duplicate is an error", !store.load_users(users).ok);
    fs.write_file(users, "bob 0011 lic-1\n");
    check("users: short secret is an error", !store.load_users(users).ok);
    fs.write_file(users, "bob " + s1 + "\n");
    check("users: a missing licence is an error", !store.load_users(users).ok);
    fs.write_file(users, "bob " + s1 + " lic-1\nalice " + s1 + " lic-2\n");
    check("users: lookup", store.find_user(store.load_users(users).users, "alice") != none);
    check("users: unknown lookup", store.find_user(store.load_users(users).users, "carol") == none);

    let raw = dir + "/raw";
    let hex = dir + "/hex";
    let raw32: [byte] = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6,
        7, 8, 9, 1, 2, 3, 4, 5, 6, 7, 8, 9, 1, 2, 3, 4];
    fs.write_bytes(raw, raw32);
    fs.write_file(hex, s1);
    check("key: raw", store.key_material(raw, 16) != none);
    check("key: hex", store.key_material(hex, 16) != none);
    check("key: too short", store.key_material(dir + "/missing", 16) == none);

    let tokh = "00112233445566778899aabbccddeeff";
    let tokf = dir + "/tokens";
    fs.write_file(tokf, tokh + "\n" + "ffeeddccbbaa99887766554433221100\n");
    let tl = store.load_tokens(tokf);
    check("tokens: hex list", tl.ok && len(tl.tokens) == 2 && len(tl.tokens[0]) == 16);
    fs.write_bytes(tokf, raw16);
    let tr = store.load_tokens(tokf);
    check("tokens: one raw token", tr.ok && len(tr.tokens) == 1 && len(tr.tokens[0]) == 16);
    fs.write_file(tokf, "0011\n");
    check("tokens: short file is an error", !store.load_tokens(tokf).ok);

    let nhex = "";
    let dhex = "";
    for i in 0..256 { nhex += "ab"; dhex += "cd"; };
    let pubf = dir + "/rsa.pub";
    let privf = dir + "/rsa.key";
    fs.write_file(pubf, nhex + "\n010001\n");
    fs.write_file(privf, nhex + "\n" + dhex + "\n");
    let pk = store.load_rsa_pub(pubf);
    check("rsa: public pin", pk.ok && len(pk.n) == 256
        && crypto.hex(pk.e) == "010001");
    let sk = store.load_rsa_priv(privf);
    check("rsa: private key", sk.ok && len(sk.n) == 256 && len(sk.d) == 256);
    fs.write_file(pubf, "abababab\n");
    check("rsa: short pin is an error", !store.load_rsa_pub(pubf).ok);

    let n1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let n2 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let n3 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    check("nonce: fresh store", store.load_nonces(nf, 4).err == "");
    check("nonce: add", store.nonce_add(nf, [], n1, 4));
    let l = store.load_nonces(nf, 4);
    check("nonce: persisted", l.err == "" && store.nonce_has(l.seen, n1));
    check("nonce: duplicate seen", store.nonce_has(l.seen, n1));
    check("nonce: unknown", !store.nonce_has(l.seen, n2));
    check("nonce: second add", store.nonce_add(nf, l.seen, n2, 4));
    let l2 = store.load_nonces(nf, 3);
    check("nonce: third add", store.nonce_add(nf, l2.seen, n3, 4));
    let l3 = store.load_nonces(nf, 2);
    check("nonce: prune keeps the newest", l3.err == "" && len(l3.seen) == 2
        && store.nonce_has(l3.seen, n3) && store.nonce_has(l3.seen, n2));
    let th = crypto.sha256(bytes("transcript"));
    let th0 = crypto.hex(th);
    let ac = proto.auth_context(th, "bob", "lic-1");
    check("proto: auth_context does not mutate the transcript",
        crypto.hex(th) == th0 && len(ac) == len(th) + 4 + 3 + 4 + 5);
    let a1 = proto.aad(th, "client-auth");
    let a2 = proto.aad(th, "client-auth");
    check("proto: aad is stable and copied",
        crypto.hex(a1) == crypto.hex(a2) && crypto.hex(th) == th0
            && len(a1) == len(th) + 11);
    let b: [byte] = [1, 2, 3, 4];
    store.wipe(b);
    check("wipe", b[0] == 0 && b[3] == 0);

    fs.remove_all(dir);
    if (bad == 0) { print("keyserver selftest: OK"); }
    else { print("keyserver selftest: " + tostring(bad) + " failure(s)"); };
    bad
};

let r = main();
exit(r);
