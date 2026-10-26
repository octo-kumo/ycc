// Public no-GC default: use raw_cmd so the legacy corpus's GC opt-in cannot
// mask a policy regression. Check the actual listing as well as diagnostics.
import fs;
import yt;
import yc;

def probe(cc: str, name: str, src: str, flags: [str], want: str, accepted: bool) -> void {
    let d = yt.tmp_dir("lifetime");
    let file = d + "/main.y";
    yt.write(file, src);
    let c = yt.raw_cmd([cc] + flags + [file, "-o", d + "/a"]);
    c.merge = true;
    let r = yt.run(c);
    if (!accepted) {
        yt.check("lifetime " + name, r.code == 1 && r.out.contains("lifetime:") && r.out.contains("--gc=auto") && !fs.exists(d + "/a"), yt.clip(r.out, 400));
    } else if (r.code != 0) {
        yt.fail("lifetime " + name, yt.clip(r.out, 400));
    } else {
        let run = yc.run_bin(d + "/a", [], "", 10);
        yt.check("lifetime " + name, run.code == 0 && run.out == want, yt.clip(run.out, 400));
        let listing = yt.raw_cmd([cc] + flags + ["--emit=asm", file]);
        listing.merge = true;
        let asm = yt.run(listing);
        yt.check("lifetime " + name + " has no collector", asm.code == 0 && !asm.out.contains("y_gc_collect:"), yt.clip(asm.out, 200));
    };
    fs.remove_all(d);
};

def one(cc: str) -> void {
    let stub = yt.raw_cmd([cc, "--gc=never", "--emit=asm", yc.ROOT + "/src/y/packstub.y"]);
    stub.merge = true;
    let launcher = yt.run(stub);
    yt.check("lifetime pack launcher has no collector", launcher.code == 0 && !launcher.out.contains("y_gc_collect:"), yt.clip(launcher.out, 300));
    probe(cc, "audited assembly", "import math;\nprint(math.sqrt(16.0)==4.0);", [], "true\n", true);
    probe(cc, "implicit bigint return survives", "def make()->bigint { let scratch=[1]; scratch[0]+41 }; print(make());", [], "42\n", true);
    probe(cc, "implicit union return survives", "type V=long|str; def make()->V { let scratch=[7]; scratch[0] }; print(make());", [], "7\n", true);
    probe(cc, "assembly return survives", "ndef zeroes(n:long)->[byte]=\"y_bytes_zero\"; def make()->[byte] { let scratch=[1]; zeroes(scratch[0]+7) }; print(make().length);", [], "8\n", true);
    probe(cc, "numeric puts scratch", "for i in 0..3 { puts(i); };", [], "012", true);
    probe(cc, "string membership scratch", "let s=0; for i in 0..3 { if (\"a\" in \"abcd\") {s+=1;}; }; print(s);", [], "3\n", true);
    probe(cc, "retained bigint promotion", "let kept:bigint=0; for i in 0..3 { kept=i; }; print(kept);", [], "", false);
    probe(cc, "retained union boxing", "type V=long|str; let kept:V=0; for i in 0..3 { kept=i; }; print(kept);", [], "", false);
    probe(cc, "bigint increment", "let kept=0n; for i in 0..3 { kept++; }; print(kept);", [], "", false);
    probe(cc, "push conversion", "type V=long|str; let kept:[V]=[]; for i in 0..3 { kept.push(i); }; print(kept.length);", [], "", false);
    probe(cc, "removed array scratch", "let a=[1,2,3]; for i in 0..3 { let b=a.remove(0,1); print(b.length); };", [], "1\n1\n1\n", true);
    probe(cc, "callback promotions", "let a=[1,2,3].map(def(n:bigint)->long { 1 }); print(a.length);", [], "", false);
    probe(cc, "lock callback effects", "let m=mutex(); let kept:[str]=[]; lock(m, ()=>{ for i in 0..3 { kept += tostring(i); }; }); print(kept.length);", [], "", false);
    probe(cc, "call arena cannot conceal loop garbage", "def work(n:long)->long { let s=\"\"; for i in 0..n { s=s+tostring(i); }; s.length }; print(work(10));", [], "", false);
    probe(cc, "one-shot", "let a = [1,2,3]; print(a[1]);", [], "2\n", true);
    probe(cc, "temporary loop", "let s=0; for i in 0..10000 { let a=[i,i+1]; s += a[0]; }; print(s);", [], "49995000\n", true);
    probe(cc, "scalar helper", "def size(i:long)->long { let a=[i,i+1]; a[0] }; let s=0; for i in 0..10 { s += size(i); }; print(s);", [], "45\n", true);
    probe(cc, "allocating condition", "let ticks=0; def step()->bool { ticks += 1; let s=tostring(ticks); s.length < 2 }; while(step()) { }; print(ticks);", [], "10\n", true);
    probe(cc, "recursive scratch", "def sum(n:long)->long { let a=[n]; if(n==0){a[0]}else{a[0]+self(n-1)} }; print(sum(100));", [], "5050\n", true);
    probe(cc, "array growth", "let a:[long]=[]; for i in 0..100 { a += i; }; print(a.length);", [], "100\n", true);
    probe(cc, "pure callback", "let a=[1,2,3].map((n:long)=>n*2); print(a[2]);", [], "6\n", true);
    probe(cc, "explicit region", "let s=0; for i in 0..100 { region { let a=[i;1000]; s += a[0]; } }; print(s);", [], "4950\n", true);
    probe(cc, "return unwinds", "def pick(i:long)->long { region { let a=[i;1000]; if(i>0){return a[999];}; }; -1 }; let s=0; for i in 0..100 { s += pick(i); }; print(s);", [], "4949\n", true);
    probe(cc, "unused unsafe def", "def unused()->[long] { let a:[long]=[]; for i in 0..10 { a=a+[i]; }; a }; print(7);", [], "7\n", true);
    let leak = "let a:[str]=[]; for i in 0..3 { a += tostring(i); }; print(a.length);";
    probe(cc, "escaping loop", leak, [], "", false);
    probe(cc, "explicit never", leak, ["--gc=never"], "", false);
    probe(cc, "recursive result", "def nest(n:long)->[long] { if(n==0){[n]}else{self(n-1)+[n]} }; print(nest(4));", [], "", false);
    probe(cc, "heap bypass", "for i in 0..3 { region { heap { let a=[i]; print(a[0]); } } };", [], "", false);
    probe(cc, "known scalar callback", "def invoke(f:()->long)->long { f() }; print(invoke(()=>1));", [], "1\n", true);
    probe(cc, "forwarded scalar callback", "def invoke(f:()->long)->long { f() }; def forward(f:()->long)->long { invoke(f) }; print(forward(()=>7));", [], "7\n", true);
    probe(cc, "recursive callback effects", "let kept:[str]=[]; def bad()->long { heap { kept += tostring(1); }; 1 }; def invoke(n:long,f:()->long)->long { if(n>0){self(0,bad)}else{f()} }; print(invoke(1,()=>7));", [], "", false);
    probe(cc, "known callback keeps heap", "let kept:[str]=[]; def invoke(f:()->long)->long { f() }; for i in 0..3 {print(invoke(()=>{heap {kept += tostring(1);};1}));};", [], "", false);
    probe(cc, "callback alias stays conservative", "def invoke(f:()->long)->long { let g=f; g() }; print(invoke(()=>1));", [], "", false);
    probe(cc, "function accepting callbacks escapes", "def invoke(f:()->long)->long { f() }; print(invoke(()=>1)); let a=[()=>2].map(invoke); print(a[0]);", [], "", false);
    probe(cc, "compound assignment return survives", "def add(a:[long])->[long] { a += 7 }; def make()->[long] { let a:[long]=[]; add(a) }; let a=make(); for i in 0..100 {let scratch=[i;100];}; print(a[0]);", [], "7\n", true);
    probe(cc, "bigint increment return survives", "def pre()->bigint { let n=7n; ++n }; def post()->bigint { let n=7n; n++ }; let a=pre(); let b=post(); for i in 0..100 {let scratch=[i;100];}; print(a,b);", [], "87\n", true);
    probe(cc, "process arena retains pass state", "let state:[str]=[]; def work()->long { for i in 0..3 {state += tostring(i);}; print(state); 0 }; region {exit(work());}", [], "[0, 1, 2]\n", true);
    probe(cc, "process arena retains heap caches", "let state:[str]=[]; def work()->long { for i in 0..3 {heap {state += tostring(i);};}; print(state.length); 0 }; region {exit(work());}", [], "3\n", true);
    probe(cc, "process arena keeps unknown calls unsafe", "ndef unknown()->long=\"y_user_unknown\"; region {exit(unknown());}", [], "", false);
    probe(cc, "process arena keeps threads unsafe", "def work()->long { let t=spawn(()=>print(1)); join(t); 0 }; region {exit(work());}", [], "", false);
    probe(cc, "process arena checks threads with GC too", "def work()->long { let t=spawn(()=>print(1)); join(t); 0 }; region {exit(work());}", ["--gc=auto"], "", false);
    probe(cc, "thread fallback", "let t=spawn(()=>{for i in 0..3 {print([i]);}}); join(t);", [], "", false);
    probe(cc, "callback allocations", "let a=[1,2,3].map((n:long)=>tostring(n)); print(a.length);", [], "", false);
    probe(cc, "closure keeps scratch", "def make()->()->long { let a=[7]; ()=>a[0] }; let a:[()->long]=[]; for i in 0..3 { a += make(); }; print(a.length);", [], "", false);
    probe(cc, "runtime replacement", "let kept:[str]=[]; def y_print_long(n:long)->long { heap { kept += tostring(n); }; 0 }; print(3);", [], "", false);

    let d = yt.tmp_dir("lifetime-import");
    yt.write(d + "/helper.y", "def work(n:long)->long { let a=[n;100]; a[0] };\nexport { work };\n");
    yt.write(d + "/main.y", "import h from \"./helper.y\";\nprint(h.work(10));\n");
    let c = yt.raw_cmd([cc, d + "/main.y", "-o", d + "/a"]);
    c.merge = true;
    let imported = yt.run(c);
    // A source import is spliced, so the scalar helper gets its own proved
    // region. The caller does not need to know its implementation.
    yt.check("lifetime source import", imported.code == 0 && yc.run_bin(d + "/a", [], "", 10).out == "10\n", yt.clip(imported.out, 300));
    yt.write(d + "/main.y", leak);
    foreach (flag in ["--gc=auto", "--gc=always", "--gc=stress"]) {
        let opt = yt.raw_cmd([cc, flag, d + "/main.y", "-o", d + "/a"]);
        opt.merge = true;
        let r = yt.run(opt);
        yt.check("lifetime opt-in " + flag, r.code == 0 && yc.run_bin(d + "/a", [], "", 10).out == "3\n", yt.clip(r.out, 300));
    };
    yt.write(d + "/main.y", "print(7);\n");
    let packed = yt.raw_cmd([cc, "--pack", d + "/main.y", "-o", d + "/packed"]);
    packed.merge = true;
    let packed_result = yt.run(packed);
    yt.check("lifetime checked program runs packed", packed_result.code == 0 && yc.run_bin(d + "/packed", [], "", 10).out == "7\n", yt.clip(packed_result.out, 300));
    // More than 32 MiB per turn used to permanently turn automatic regions
    // off. Under a 64 MiB cap, three turns distinguish that leak from reuse.
    yt.write(d + "/main.y", "let s=0; for i in 0..3 { let a=[i;5000000]; s += a[4999999]; }; print(s);\n");
    let large = yt.run(yt.raw_cmd([cc, d + "/main.y", "-o", d + "/a"]));
    let run = yt.raw_cmd([d + "/a"]);
    run.mem_kb = 65536;
    run.merge = true;
    let result = if (large.code == 0) { yt.run(run) } else { large };
    yt.check("lifetime large automatic region remains bounded", large.code == 0 && result.code == 0 && result.out == "3\n", yt.clip(result.out + result.err, 300));
    fs.remove_all(d);
    package_checks(cc);
};

def project_build(cc: str, dir: str, flags: [str]) -> yt.Res {
    let c = yt.raw_cmd([cc, "build"] + flags + [dir]);
    c.merge = true;
    yt.run(c)
};

def package_checks(cc: str) -> void {
    let d = yt.tmp_dir("lifetime-package");
    fs.make_dirs(d + "/lib");
    fs.make_dirs(d + "/app");
    yt.write(d + "/lib/y.toml", "[package]\nname=\"helper\"\nlib=\"lib.y\"\n");
    yt.write(d + "/lib/lib.y", "let kept:[str]=[];\ndef touch(n:long)->long { heap { kept += tostring(n); }; n };\n");
    yt.write(d + "/app/y.toml", "[package]\nname=\"app\"\n[bin]\napp=\"main.y\"\n[dependencies]\nhelper={path=\"../lib\"}\n");
    yt.write(d + "/app/main.y", "import helper;\nlet s=0; for i in 0..3 { s += helper.touch(i); }; print(s);\n");
    let enabled = project_build(cc, d + "/app", ["--gc=auto"]);
    yt.check("lifetime package opt-in", enabled.code == 0 && yc.run_bin(d + "/app/build/app", [], "", 10).out == "3\n", yt.clip(enabled.out, 300));
    let checked = project_build(cc, d + "/app", []);
    yt.check("lifetime cached scalar package cannot hide heap allocations", checked.code == 1 && checked.out.contains("lifetime:"), yt.clip(checked.out, 400));
    yt.write(d + "/lib/lib.y", "def touch(n:long)->long { let a=[n;100]; a[99] };\n");
    let safe = project_build(cc, d + "/app", []);
    yt.check("lifetime package scratch proof", safe.code == 0 && yc.run_bin(d + "/app/build/app", [], "", 10).out == "3\n", yt.clip(safe.out, 400));
    let cached = project_build(cc, d + "/app", []);
    yt.check("lifetime cached package preserves proof", cached.code == 0 && !cached.out.contains("compiling helper"), yt.clip(cached.out, 300));
    // Initializers matter even when a package exports no function at all.
    yt.write(d + "/lib/lib.y", "let kept:[str]=[];\nfor i in 0..3 { kept += tostring(i); };\n");
    yt.write(d + "/app/main.y", "import helper;\nprint(7);\n");
    let init = project_build(cc, d + "/app", []);
    yt.check("lifetime package initializer checked without exports", init.code == 1 && init.out.contains("lifetime:"), yt.clip(init.out, 400));
    fs.remove_all(d);
};

def cases() -> [yt.Case] {
    [yt.case_of("lifetime", "native", () => one(yc.YREF)), yt.case_of("lifetime", "cycc", () => one(yc.CYCC))]
};

export { cases };
