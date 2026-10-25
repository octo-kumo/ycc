// b1_exec -- execve with argv and envp, close-on-exec, relative path, errors
import b1 from "./b1.y";

def cbytes(s: str) -> [byte] { let b = bytes(s); b += 0; b };

def itoa(n: long) -> str { tostring(n) };

let keep: [long] = [0, 0];
let gone: [long] = [0, 0];
let out: [long] = [0, 0];

/** Fork and exec `path` with the two descriptors named in argv; the child's output goes to `out`. */
def start(path: str) -> long {
    let c = b1.fork();
    if (c == 0) {
        b1.close(out[0]);
        b1.dup2(out[1], 1);
        let pa = cbytes(path);
        let a0 = cbytes("b1");
        let a1 = cbytes("child");
        let a2 = cbytes(itoa(keep[1]));
        let a3 = cbytes(itoa(gone[1]));
        let argv: [long; 5] = [ptr_addr(&a0[0]), ptr_addr(&a1[0]), ptr_addr(&a2[0]), ptr_addr(&a3[0]), 0];
        let e0 = cbytes("B1KEY=value1");
        let e1 = cbytes("B1B=2");
        let envp: [long; 3] = [ptr_addr(&e0[0]), ptr_addr(&e1[0]), 0];
        let r = b1.sc(59, ptr_addr(&pa[0]), ptr_addr(&argv[0]), ptr_addr(&envp[0]), 0);
        exit(100 - r);
    };
    c
};

def run_exec() -> void {
    let k0 = b1.pipe();
    keep[0] = k0[0];
    keep[1] = k0[1];
    let g0 = b1.pipe2(524288);
    gone[0] = g0[0];
    gone[1] = g0[1];
    let o0 = b1.pipe();
    out[0] = o0[0];
    out[1] = o0[1];
    let c = start("/bin/b1");
    b1.close(out[1]);
    let text = b1.rd_all(out[0]);
    b1.wait4(c, 0);
    puts(text);
    b1.eq("child status", b1.wstatus(), 9 * 256);
    b1.close(keep[1]);
    b1.close(gone[1]);
    b1.check("inherited fd carried data", b1.rd(keep[0], 100) == "from-child");

    // a relative path resolves against the working directory
    let out2 = b1.pipe();
    out[0] = out2[0];
    out[1] = out2[1];
    let keep2 = b1.pipe();
    keep[0] = keep2[0];
    keep[1] = keep2[1];
    let gone2 = b1.pipe2(524288);
    gone[0] = gone2[0];
    gone[1] = gone2[1];
    let c3 = start("../../bin/b1");
    b1.close(out[1]);
    let t2 = b1.rd_all(out[0]);
    b1.wait4(c3, 0);
    b1.check("relative exec ran", len(t2) > 0);
    b1.eq("relative exec status", b1.wstatus(), 9 * 256);

    // a missing program: the child sees -ENOENT
    let c4 = start("/no/such/prog");
    b1.wait4(c4, 0);
    b1.eq("exec of a missing file", 100 - (b1.wstatus() / 256), 0 - 2);
    puts("done\n");
};
