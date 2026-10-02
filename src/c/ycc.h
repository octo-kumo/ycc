#ifndef YCC_H
#define YCC_H

#include "yv.h"

/* ycc.y's defs (the driver) */
Yv *parse_cli_args(Yv *argv);
Yv *padr(Yv *s, long w);
Yv *padl(Yv *s, long w);
Yv *fmt_ms(long us);
Yv *fmt_kb(long b);
long print_phase_rows(Yv *times);
long print_counter(Yv *name, long v);
long print_native_errors(Yv *errors, Yv *origin, int bare);
long print_native_warnings(Yv *warnings, Yv *origin, int bare);
long y_main(Yv *cmdline);

#endif /* YCC_H */
