/* ylong.h — the C spelling of Y's `long` (C-only, like yv.h).
 *
 * Y's `long` is 64 bits on every host. C's `long` is 64 on LP64 (Linux) and 32
 * on Windows (LLP64), and the C copy's whole value model — `Yv.l`, the
 * checker's constants, the emitter's offsets — assumes 64. So the C twin
 * spells Y's integer type `ylong`, and this one typedef makes it the same
 * width everywhere: on LP64 it *is* `long`, so the Linux build and every byte
 * it emits are unchanged; on Windows it is a 64-bit type and the model holds.
 *
 * PORTING.md's scalar mapping is therefore `long -> ylong` (not `long -> long`),
 * the same way Y's `bool` maps to C's `int`. Include this before any use; the
 * transform covered every src/c source, and the only places that must stay
 * C's `long` are calls into a system header whose own prototype says `long`
 * (there are none left that matter: `strtol` became `strtoll`, and the two
 * `%ld` format sites print a `long long`).
 */
#ifndef Y_LONG_H
#define Y_LONG_H

#include <stdint.h>

#ifdef _WIN32
typedef int64_t ylong;
#else
typedef long ylong;
#endif

#endif /* Y_LONG_H */
