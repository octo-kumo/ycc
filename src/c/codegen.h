#ifndef CODEGEN_H
#define CODEGEN_H

#include "ast.h"
#include <stdio.h>

/*
 * C code generation backend.
 *
 * Translates the AST into C source code that links against runtime.c.
 * The generated program, when compiled with gcc, produces a native binary
 * that executes the .y program without the interpreter/VM.
 *
 * Usage:
 *   codegen_compile(ast, output_binary_path)
 *     -> writes a temp .c file, invokes gcc, produces the binary
 *
 *   codegen_emit(ast, FILE *out)
 *     -> writes C source to the given file handle (for inspection / -S mode)
 */

/* Emit C source code for the given AST to `out`. Returns 0 on success. */
int codegen_emit(Expr *ast, FILE *out);

/* Full pipeline: emit C to a temp file, compile with cc, produce binary at
 * `output_path`. Returns 0 on success, non-zero on failure. */
int codegen_compile(Expr *ast, const char *output_path);

#endif /* CODEGEN_H */
