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

void run_tc(Expr *expr) {
    TCVarTypeScope global_scope = {0};
    map_init(&global_scope.variables);
    populate_types(&global_scope);
    typecheck_result_t res = tc_expr(expr, &global_scope);
    if (res.is_ok) {
        printf("Type check successful. Type: %s\n", type_t_to_str(res.type));
    } else {
        printf("Type check failed: %s\n", res.error_message);
        ast_print_code(stdout, res.error_expr, 0);
        printf("\n");
    }
    map_free(&global_scope.variables);
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
        } else if (strcmp(argv[i], "--no-exec") == 0) {
            set_exec_disabled(1);
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
    char *processed = module_preprocess(input, base_dir, 0);
    free(input);
    free(base_dir_alloc);
    if (!processed) {
        fprintf(stderr, "Module preprocessing failed\n");
        return 1;
    }
    input = processed;

    ast_parser_result_t res = ast_parse_expr_block(input);
    if (!res.is_some) {
        printf("failed :: remaining='%s'\n", res.remaining);
        free(input);
        return 1;
    }

    if (!quiet) printf("success\n");

    if (mode == MODE_COMPILE) {
        /* Type-check first */
        run_tc(res.value);
        printf("\n");

        const char *out = output_path ? output_path : "a.out";
        int ret = codegen_compile(res.value, out);
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

    if (res.remaining[0] != '\0' && !quiet) {
        printf("Warning: Unparsed input remaining: '%s'\n", res.remaining);
    }

    if (!quiet) printf("\ncomplete\n");
    ast_free(res.value);
    free(input);
    return 0;
}
