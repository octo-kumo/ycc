#ifndef Y_MODULE_H
#define Y_MODULE_H

/* Multi-file module support (TypeScript-style import/export).
 *
 * Implemented as a source-to-source preprocessing pass that runs before the
 * parser, so it works identically for the VM and the compiled backend.
 *
 *   ── module file (math.y) ──────────────────────────────
 *      def add(a: long, b: long) { a + b };
 *      def sub(a: long, b: long) { a - b };
 *      export { add, sub };          // must be the last statement
 *
 *   ── importer (main.y) ─────────────────────────────────
 *      import math from "./math.y";
 *      print(math.add(1, 2));
 *
 * Rewriting rules:
 *   import NAME from "PATH";   ->  let NAME = { <preprocessed PATH> };
 *   export { a, b };           ->  { a: a, b: b }   (the module's value)
 *
 * Imports are resolved relative to the importing file's directory and are
 * processed recursively (a module may import other modules). */

/* Preprocess `source`, resolving imports against `base_dir`.
 * Returns a freshly malloc'd string (caller frees), or NULL on error
 * (an error message is printed to stderr). `depth` guards against
 * import cycles / runaway recursion. */
char *module_preprocess(const char *source, const char *base_dir, int depth);

#endif /* Y_MODULE_H */
