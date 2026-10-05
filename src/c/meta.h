/* meta.h — compile-time code generation: the `#{ … }#` block, and the image
 * runner it needs. 1:1 C copy of src/y/meta.y (see PORTING.md).
 *
 * run_image(b: [byte], av: [str], want_out: bool) -> RunRes
 *   { ok: bool, status: long, sig: long, out: [byte], err: str }
 * meta_begin()                    one pass, on, at the start of a resolve
 * mg_pass()                       a new pass over the same files (the block
 *                                 table, G's body and the hoisted imports are
 *                                 all per-pass; the pieces are not)
 * mg_set(on)                      the pass is off while G is compiled
 * mg_setup(root, files, base, exec, pkgs, roots)
 *                                 G's resolution (native.y hands it over:
 *                                 `meta.<field> = v` does not work, because
 *                                 strip_ns rewrites dot READS only)
 * meta_scan(src, fid, dir) -> Scan { ok, err, eline, ecol, p, pf, pol, gen,
 *                                     g, gf, gol }
 * meta_gtext() -> str             G's text: helpers, hoisted imports, body
 * mg_ghead(), mg_glines()         how many lines of each G's origin map has
 * mg_take_pieces(status, sig, out) -> bool
 * mg_probe(src, dir) -> bool      is there a `#{` in text the generator
 *                                 resolved (a module it imported)?
 * mg_check(s), mg_report(msg)
 * scan_none(src, fid) -> Scan     the pass-off scan
 * run_image / elf_img             M1, the image runner
 */
#ifndef META_H
#define META_H

#include "yv.h"

/* ── the pass's globals the other modules read ──────────────────────────── */
extern int mg_on;          /* whether the pass runs at all */
extern Yv *mg_gol;         /* the source line each line of G came from */
extern Yv *mg_gbase;       /* G's own dir */
extern int mg_gexec;       /* whether exec() is allowed in G */
extern Yv *mg_pkgs;        /* the package names G's bare imports resolve against */
extern Yv *mg_roots;       /* and their source roots */
extern Yv *mg_root;        /* the program file's path */
extern long mg_n;          /* how many blocks the whole resolve found */

long meta_begin(void);
long mg_pass(void);
long mg_set(int on);
long mg_setup(Yv *root, Yv *files, Yv *base, int exec, Yv *pkgs, Yv *roots);
long mg_check(long s);
long mg_report(Yv *msg);
int mg_probe(Yv *src, Yv *dir);
int mg_take_pieces(long status, long sig, Yv *out);
Yv *meta_scan(Yv *src, long fid, Yv *dir);
Yv *scan_none(Yv *src, long fid);
Yv *meta_gtext(void);
long mg_ghead(void);
long mg_glines(void);

/* ── the image runner ──────────────────────────────────────────────────── */
Yv *run_image(Yv *b, Yv *av, int want_out);
Yv *elf_img(Yv *b);

#endif /* META_H */