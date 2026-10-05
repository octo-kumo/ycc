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
//   file       size    scan      index      classify           heap
//   tags.y       8 KB    0 ms     0 ms /   0.4 MB
//   lint.y      42 KB    1 ms     2 ms /   3.2 MB
//   types.y    191 KB    5 ms     7 ms /  12.7 MB
//   native.y   497 KB   13 ms    20 ms /  31.8 MB     <- the largest file here
//
// Before the `to_lsp` fix (LSP.md 11.2, item 2) the `index` column read 0, 65,
// 973 and 5,499 ms, and the heap column 0.5, 43, 584 and 2,541 MB. So the fix is
// worth 275x on the largest file -- not because 20 ms is fast, but because 5.5 s
// is the difference between a feature and a hang.
import scan from "../scan.y";
import scope from "../scope.y";
import nav from "../nav.y";
// `serve` rather than `import fs`: serve path-imports std/fs and flattens it, so a
// bare `import fs` beside it is a duplicate definition of every name fs exports.
import serve from "../serve.y";
import sem from "../sem.y";
import pos from "../pos.y";

foreach (f in ["src/y/tags.y", "src/y/lint.y", "src/y/types.y", "src/y/native.y"]) {
    let src = serve.fs.read_file(f)!;
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
    // semanticTokens/full is the other whole-buffer request, and since the
    // semantic classes landed it has a third phase: `classify` asks, once per
    // identifier, what the name resolves to. That is a linear walk of the
    // declarations per identifier -- the same order as `visible()`, but over EVERY
    // identifier rather than one position -- so it is the phase that decides
    // whether the highlighter is usable on a big file.
    // `classify` in two, because "it is slow" is not a finding: by_name is the
    // once-per-buffer bucket build and the rest is the per-identifier work.
    let tb0 = clock_us();
    let byn = nav.by_name(idx);
    let tb1 = clock_us();
    print("   by_name " + tostring((tb1 - tb0) / 1000) + " ms  " + tostring(len(keys(byn))) + " names");
    // The same walk with NO classification, which is the floor: if this is most of
    // `classify` then the span loop is the cost and the classification is nearly
    // free, and the two need different fixes.
    let tt0 = clock_us();
    let base = sem.tokens_in(pos.doc_of(src), []);
    let tt1 = clock_us();
    print("   tokens_in (no classes) " + tostring((tt1 - tt0) / 1000) + " ms  " + tostring(len(base)) + " tokens");
    let t5 = clock_us();
    let h3 = heap_used();
    let over = serve.classify_text(src, f);
    let t6 = clock_us();
    let h4 = heap_used();
    let n_over = 0;
    let oi = 0;
    while (oi < len(over)) { if (over[oi] != 0) { n_over = n_over + 1; }; oi = oi + 1; };
    print("   classify " + tostring((t6 - t5) / 1000) + " ms  +" + tostring((h4 - h3) / 1024) +
          " KB  " + tostring(n_over) + " of " + tostring(len(over)) + " spans classified");
};
