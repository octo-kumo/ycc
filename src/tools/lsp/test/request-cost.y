// request-cost.y -- what one M4 request costs, measured per phase, on the
// largest files in the tree.
//
//   ./ycc src/tools/lsp/test/request-cost.y -o /tmp/rc && /tmp/rc
//
// It exists because "the server must not block" (R1.1, R6.4) is a claim about
// TIME, and the number behind it was 5.5 SECONDS -- which is not a slow feature,
// it is a frozen editor. Every request re-derives the whole index from scratch,
// because the protocol gives no notice that only a few lines changed, so the cost
// is paid per keystroke. The phase split is the point: `scan` is the tolerant
// tokeniser and `index` is scope.index_src, and only the second one was ever a
// problem.
//
// Measured on this machine, whole-file, both phases plus visible():
//
//   file       size    scan      index           heap
//   tags.y       8 KB    0 ms     0 ms /   0.4 MB
//   lint.y      42 KB    1 ms     2 ms /   3.2 MB
//   types.y    191 KB    5 ms     7 ms /  12.7 MB
//   native.y   497 KB   13 ms    20 ms /  31.8 MB     <- the largest file here
//
// Before the `to_lsp` fix (LSP.md 11.2, item 2) the `index` column read 0, 65,
// 973 and 5,499 ms, and the heap column 0.5, 43, 584 and 2,541 MB. So the fix is
// worth 275x on the largest file -- not because 20 ms is fast, but because 5.5 s
// is the difference between a feature and a hang.
import fs;
import scan from "../scan.y";
import scope from "../scope.y";
import nav from "../nav.y";

foreach (f in ["src/y/tags.y", "src/y/lint.y", "src/y/types.y", "src/y/native.y"]) {
    let src = fs.read_file(f)!;
    let bytes = len(src);
    let h0 = heap_used();
    let t0 = clock_us();
    let sps = scan.scan_full(src).spans;
    let t1 = clock_us();
    let h1 = heap_used();
    let idx = scope.index_src(src, f);
    let t2 = clock_us();
    let h2 = heap_used();
    // A completion is index + visible() over the decls at a position.
    let t3 = clock_us();
    let vis = nav.visible(idx, 100, 0);
    let t4 = clock_us();
    print(f + ": " + tostring(bytes / 1000) + " KB, " + tostring(len(sps)) + " spans, " +
          tostring(len(idx.decls)) + " decls");
    print("   scan  " + tostring((t1 - t0) / 1000) + " ms  +" + tostring((h1 - h0) / 1024) + " KB");
    print("   index " + tostring((t2 - t1) / 1000) + " ms  +" + tostring((h2 - h1) / 1024) + " KB");
    print("   visible() " + tostring(t4 - t3) + " us  " + tostring(len(vis)) + " names");
};
