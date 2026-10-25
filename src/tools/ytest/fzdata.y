// fzdata.y -- `ytest fuzz --data`: mutated inputs for the std decoders that
// parse outside bytes. test/fuzz/data.y mutates the seeds of one decoder in
// process and writes each input to a file before the call, so a trap, a
// timeout or the memory cap leaves the offending input behind. A finding is
// saved under `out` with the decoder's message and becomes a hostile-input
// case in that decoder's t* fixture.
import fs;
import yt;
import yc;

const TARGETS = ["audio", "img", "zlib", "json", "regex", "utf8"];

// Build the harness once; "" after reporting why there is none.
def build(work: str) -> str {
    fs.make_dirs(work);
    let bin = work + "/data";
    let r = yc.compile(yc.YCC, [], yc.ROOT + "/test/fuzz/data.y", bin, 300);
    if (r.code != 0) { print("fuzz --data: cannot build data.y\n" + yt.clip(r.out, 600)); return ""; };
    bin
};

// iter inputs of one decoder; true when none of them is a finding.
def run_target(bin: str, work: str, target: str, iter: long, seed: long, out: str) -> bool {
    let cur = work + "/cur." + target;
    let c = yt.cmd([bin, target, tostring(seed), tostring(iter), cur]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 300 * yt.SCALE;
    let r = yt.run(c);
    if (r.code == 0) { return true; };
    fs.make_dirs(out);
    let f = out + "/data-" + target + "-" + tostring(seed);
    fs.copy_file(cur, f + ".bin");
    let why = if (r.timed_out) { "timeout" } else { yt.first_line(r.out) };
    yt.write(f + ".txt", "ytest fuzz --data " + tostring(iter) + " " + tostring(seed) + " (" + target + ") rc="
        + tostring(r.code) + "\n" + yt.clip(r.out, 1000) + "\n");
    print("finding: " + f + ".bin (" + target + ", rc=" + tostring(r.code) + ") " + yt.clip(why, 100));
    false
};

// ytest fuzz --data [ITER] [SEED]
def main(av: [str]) -> long {
    let iter = if (av.length > 0) { yt.num(av[0], 10000) } else { 10000 };
    let seed = if (av.length > 1) { yt.num(av[1], 1) } else { clock_us() % 32768 };
    let out = yc.abs_path(yt.env("FUZZ_OUT", "_check/fuzz"));
    let work = yt.tmp_dir("fzdata");
    let bin = build(work);
    if (bin == "") { return 2; };
    print("fuzz --data: " + tostring(iter) + " inputs per decoder, seed " + tostring(seed) + ", findings in " + out);
    let found = 0;
    foreach (t in TARGETS) {
        if (!run_target(bin, work, t, iter, seed, out)) { found += 1; };
    };
    fs.remove_all(work);
    print("fuzz --data: " + tostring(found) + " decoder(s) with a finding");
    if (found == 0) { 0 } else { 1 }
};

export { TARGETS, build, run_target, main };
