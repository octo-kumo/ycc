// memstat: the heap counters agree with each other and with what the program did.
import memstat;

def check(name: str, ok: bool) -> void {
    puts(name + ": " + (if (ok) { "ok" } else { "FAIL" }) + "\n");
};

let before = memstat.census();
let keep: [str] = [];
let i = 0;
while (i < 5000) { keep += "item " + tostring(i); i = i + 1; };
let big: [byte] = [0; 300000];
let r = memstat.census();
check("chunks", r[memstat.C_CHUNKS] >= 1 && r[memstat.C_CHUNKS] == memstat.chunk_count());
check("mapped", r[memstat.C_MAPPED] == memstat.mapped() && memstat.mapped() >= memstat.used());
check("blocks grew", r[memstat.C_LIVE_BLOCKS] >= before[memstat.C_LIVE_BLOCKS] + 5000);
check("bytes grew", r[memstat.C_LIVE_BYTES] - before[memstat.C_LIVE_BYTES] >= 300000);
check("largest", r[memstat.C_LARGEST] >= 300000);
check("pointer-free", r[memstat.C_PF_BYTES] >= 300000 && r[memstat.C_PF_BYTES] <= r[memstat.C_LIVE_BYTES]);
check("used", memstat.used() == heap_used() && r[memstat.C_LIVE_BYTES] <= memstat.mapped());
check("classes", r[memstat.C_CLASS0] + r[memstat.C_CLASS0 + 2] > 0);
let n = 0;
let k = 0;
while (k < memstat.NCLASS) { n = n + r[memstat.C_CLASS0 + 2 * k]; k = k + 1; };
check("class sum", n == r[memstat.C_LIVE_BLOCKS]);
check("trigger", memstat.gc_trigger() >= 12582912);
check("since", memstat.since_gc() >= 0);
let rep = memstat.report();
check("report", rep.starts_with("heap: ") && rep.contains("blocks: "));
check("rss", memstat.rss_kb() != 0);
puts(tostring(len(keep) + len(big)) + "\n");
