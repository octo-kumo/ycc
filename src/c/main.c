#include "ast.h"
#include "ast_debug.h"
#include "codegen.h"
#include "lib.h"
#include "module.h"
#include "parser.h"
#include "parser_debug.h"
#include "typecheck.h"
#include "vm.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* --time: per-phase wall clock to stderr (stdout stays clean for -S). */
static int g_timing = 0;

static long now_us(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (long)ts.tv_sec * 1000000L + (long)ts.tv_nsec / 1000L;
}

static long phase(const char *name, long start) {
    long end = now_us();
    if (g_timing)
        fprintf(stderr, "  %-12s%8ld.%03ld ms\n", name, (end - start) / 1000,
                (end - start) % 1000);
    return end;
}

/* --strict: type errors become fatal instead of advisory. Off by default
 * because the checker is still incomplete (several working examples fail
 * it), but available so a program can demand a clean check. */
static int g_strict = 0;

int run_tc_q(Expr *expr, int quiet);
int run_tc(Expr *expr);

int run_tc(Expr *expr) { return run_tc_q(expr, 0); }

int run_tc_q(Expr *expr, int quiet) {
    TCVarTypeScope global_scope = {0};
    map_init(&global_scope.variables);
    populate_types(&global_scope);
    typecheck_result_t res = tc_expr(expr, &global_scope);
    int ok = res.is_ok;
    if (res.is_ok) {
        if (!quiet)
            printf("Type check successful. Type: %s\n", type_t_to_str(res.type));
    } else {
        if (!quiet) {
            printf("Type check failed: %s\n", res.error_message);
            ast_print_code(stdout, res.error_expr, 0);
            printf("\n");
        }
        if (g_strict)
            fprintf(stderr, "type error: %s\n", res.error_message);
    }
    map_free(&global_scope.variables);
    return ok;
}

void run_vm(Expr *expr, int quiet) {
    VM vm;
    vm_init(&vm);
    VMValue *output = vm_execute(vm.globals, expr);
    if (!quiet) {
        printf("\n\nResult: ");
        val_print(output);
    }
    vm_scope_release(vm.globals);
    val_free(output);
}

char *read_file(const char *filename) {
    FILE *f = fopen(filename, "r");
    if (!f) {
        fprintf(stderr, "Failed to open file: %s\n", filename);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long length = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buffer = malloc(length + 1);
    if (!buffer) {
        fprintf(stderr, "Failed to allocate memory for file: %s\n", filename);
        fclose(f);
        return NULL;
    }
    fread(buffer, 1, length, f);
    buffer[length] = '\0';
    fclose(f);
    return buffer;
}

char *read_stdin() {
    size_t capacity = 1024;
    size_t length = 0;
    char *buffer = malloc(capacity);
    if (!buffer) {
        fprintf(stderr, "Failed to allocate memory for stdin\n");
        return NULL;
    }
    int c;
    while ((c = getchar()) != EOF) {
        if (length + 1 >= capacity) {
            capacity *= 2;
            char *new_buffer = realloc(buffer, capacity);
            if (!new_buffer) {
                fprintf(stderr, "Failed to reallocate memory for stdin\n");
                free(buffer);
                return NULL;
            }
            buffer = new_buffer;
        }
        buffer[length++] = (char)c;
    }
    buffer[length] = '\0';
    return buffer;
}

static void usage(const char *prog) {
    printf("Usage: %s [OPTIONS] [FILE]\n\n", prog);
    printf("Options:\n");
    printf("  -c, --compile [OUTPUT]  Compile to native binary (default: a.out)\n");
    printf("  -S, --emit-c [OUTPUT]   Emit C source only (default: stdout)\n");
    printf("      --no-exec           Disable the exec() builtin (no shell access)\n");
    printf("  -q, --quiet             Suppress progress output\n");
    printf("  -t, --time              Print per-phase timings to stderr\n");
    printf("      --strict            Treat type errors as fatal (exit 1)\n");
    printf("  -h, --help              Show this help\n");
    printf("\nWithout options, runs the program in the built-in VM.\n");
}

int main(int argc, char *argv[]) {
    /* Parse options */
    enum { MODE_VM, MODE_COMPILE, MODE_EMIT_C } mode = MODE_VM;
    const char *output_path = NULL;
    const char *file = NULL;
    int quiet = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 < argc) output_path = argv[++i];
        } else if (strcmp(argv[i], "-c") == 0 ||
                   strcmp(argv[i], "--compile") == 0) {
            mode = MODE_COMPILE;
        } else if (strcmp(argv[i], "-S") == 0 ||
                   strcmp(argv[i], "--emit-c") == 0) {
            mode = MODE_EMIT_C;
        } else if (strcmp(argv[i], "-q") == 0 ||
                   strcmp(argv[i], "--quiet") == 0) {
            quiet = 1;
        } else if (strcmp(argv[i], "-t") == 0 ||
                   strcmp(argv[i], "--time") == 0) {
            g_timing = 1;
        } else if (strcmp(argv[i], "--no-exec") == 0) {
            set_exec_disabled(1);
        } else if (strcmp(argv[i], "--strict") == 0) {
            g_strict = 1;
        } else {
            file = argv[i];
        }
    }

    char *input = NULL;
    const char *base_dir = ".";
    char *base_dir_alloc = NULL;
    if (file) {
        if (!quiet) printf("Reading file: %s\n", file);
        input = read_file(file);
        if (!input) {
            fprintf(stderr, "Failed to read file: %s\n", file);
            return 1;
        }
        /* derive base dir for import resolution */
        const char *slash = strrchr(file, '/');
        if (slash) {
            size_t n = (size_t)(slash - file);
            base_dir_alloc = malloc(n + 1);
            memcpy(base_dir_alloc, file, n);
            base_dir_alloc[n] = '\0';
            base_dir = base_dir_alloc;
        }
    } else {
        input = read_stdin();
        if (!input) {
            fprintf(stderr, "Failed to read from stdin\n");
            return 1;
        }
    }

    /* Resolve imports / exports (source-to-source, before parsing). */
    long t_phase = now_us();
    const long t_start = t_phase;
    if (g_timing) fprintf(stderr, "yboot --time: %s\n", file ? file : "<stdin>");
    char *processed = module_preprocess(input, base_dir, 0);
    t_phase = phase("preprocess", t_phase);
    free(input);
    free(base_dir_alloc);
    if (!processed) {
        fprintf(stderr, "Module preprocessing failed\n");
        return 1;
    }
    input = processed;

    ast_parser_result_t res = ast_parse_expr_block(input);
    t_phase = phase("parse", t_phase);
    if (!res.is_some) {
        fprintf(stderr, "syntax error: could not parse input\n");
        fprintf(stderr, "  at: %.60s\n", res.remaining);
        free(input);
        return 1;
    }

    /* Leftover input is a syntax error, not a warning. `print(1 + 2;` used
     * to parse as far as it could, drop the rest and exit 0 -- a truncated
     * program silently "succeeded". Trailing whitespace and comments are
     * fine, so skip them with the parser's own rule. */
    {
        const char *rest = skip_spaces(res.remaining);
        if (*rest != '\0') {
            fprintf(stderr, "syntax error: unexpected input (unclosed "
                            "bracket or missing ';'?)\n");
            fprintf(stderr, "  at: %.60s\n", rest);
            ast_free(res.value);
            free(input);
            return 1;
        }
    }

    if (!quiet) printf("success\n");

    /* --strict: refuse to run or emit anything when the check fails, so a
     * type error can never silently produce a binary. */
    if (g_strict && mode != MODE_COMPILE) {
        if (!run_tc_q(res.value, quiet)) {
            ast_free(res.value);
            free(input);
            return 1;
        }
    }

    if (mode == MODE_COMPILE) {
        /* Type-check first */
        int tc_ok = run_tc(res.value);
        t_phase = phase("typecheck", t_phase);
        printf("\n");
        if (g_strict && !tc_ok) {
            ast_free(res.value);
            free(input);
            return 1;
        }

        const char *out = output_path ? output_path : "a.out";
        int ret = codegen_compile(res.value, out);
        t_phase = phase("codegen+cc", t_phase);
        phase("TOTAL", t_start);
        ast_free(res.value);
        free(input);
        return ret;
    }

    if (mode == MODE_EMIT_C) {
        FILE *out = stdout;
        if (output_path) {
            out = fopen(output_path, "w");
            if (!out) {
                perror("fopen");
                ast_free(res.value);
                free(input);
                return 1;
            }
        }
        codegen_emit(res.value, out);
        t_phase = phase("emit-c", t_phase);
        phase("TOTAL", t_start);
        if (out != stdout) fclose(out);
        ast_free(res.value);
        free(input);
        return 0;
    }

    /* Default: VM mode (original behavior) */
    if (!quiet) {
        ast_walk(res.value, 0);
        ast_print_code(stdout, res.value, 0);
        printf("\n\n");
        run_tc(res.value);
    }
    vm_set_argv(argc, argv);
    run_vm(res.value, quiet);
    t_phase = phase("vm", t_phase);
    phase("TOTAL", t_start);

    if (!quiet) printf("\ncomplete\n");
    ast_free(res.value);
    free(input);
    return 0;
}
