#ifndef YCC_H
#define YCC_H

#include "ylong.h"
#include "yv.h"

/* ycc.y's defs (the driver) */
Yv *parse_cli_args(Yv *argv);
Yv *padr(Yv *s, ylong w);
Yv *padl(Yv *s, ylong w);
Yv *fmt_ms(ylong us);
Yv *fmt_kb(ylong b);
ylong print_phase_rows(Yv *times);
ylong print_counter(Yv *name, ylong v);
ylong print_native_errors(Yv *errors, Yv *origin, int bare);
ylong print_native_warnings(Yv *warnings, Yv *origin, int bare);
ylong y_main(Yv *cmdline);

#endif /* YCC_H */
