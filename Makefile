GCC=gcc
# The C compiler is a 1:1 copy of the Y compiler (see PORTING.md): it compiles .y straight to a native ELF exactly like ycc.
CFLAGS=-Wall -Wextra -std=gnu99 -g
CYC_SRCS=$(wildcard src/c/*.c)
CY_HDRS=$(wildcard src/c/*.h)
CYCC=cycc

# The Y compiler sources: what the compiler compiles (and mirrors in C).
YCC_SRCS=src/y/ycc.y src/y/lexer.y src/y/parser.y src/y/types.y src/y/native.y src/y/arch_x64.y src/y/rename.y src/y/enc64.y src/y/asm.y src/y/elf.y src/y/std/io.y src/y/std/prelude.y src/y/std/rt.y src/y/std/prof_lines.y

# The --prof runtime is embedded as source lines (spliced into instrumented
# programs). src/y/std/prof_lines.y is generated from prof.y; the C copy
# gets a generated twin with the same lines.
PROF_LINES_Y=src/y/std/prof_lines.y
PROF_LINES_C=src/c/prof_lines.c
# The std modules embed their own source as line arrays (the shipped ycc
# is a standalone ELF); the C copy gets generated twins of those arrays.
STD_LINES_C=src/c/std_lines.c

all: cycc

# [1/3] gcc builds the C copy of the compiler.
cycc: $(CYC_SRCS) $(CY_HDRS) $(STD_LINES_C) $(PROF_LINES_C)
	$(GCC) $(CFLAGS) -o cycc $(CYC_SRCS)
	@echo "cycc built: the C copy of the compiler ($$(stat -c%s cycc) bytes)"

$(STD_LINES_C): tools/gen_std_lines.py src/y/std/rt.y src/y/std/prelude.y
	python3 tools/gen_std_lines.py $@ src/y/std/rt.y:rt_lines \
	    src/y/std/prelude.y:prelude_lines src/y/std/prelude.y:exec_lines \
	    src/y/std/prelude.y:prelude_names src/y/std/prelude.y:exec_names

$(PROF_LINES_Y): src/y/std/prof.y
	{ echo '// GENERATED from src/y/std/prof.y by make -- do not edit.'; \
	  echo '// (ycc is a standalone binary: the --prof runtime is spliced'; \
	  echo '// in from this embedded copy.)'; \
	  echo 'def prof_lines() -> [str] {'; \
	  echo '    ['; \
	  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/        "/' -e 's/$$/",/' src/y/std/prof.y; \
	  echo '        ""'; \
	  echo '    ]'; \
	  echo '};'; \
	  echo ''; \
	  echo 'export { prof_lines };'; } > $@

$(PROF_LINES_C): src/y/std/prof.y
	{ echo '/* GENERATED from src/y/std/prof.y by make -- do not edit.'; \
	  echo ' * 1:1 twin of the generated src/y/std/prof_lines.y. */'; \
	  echo '#include "yv.h"'; \
	  echo ''; \
	  echo 'Yv *prof_lines(void) {'; \
	  echo '    Yv *out = yav(0);'; \
	  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/    out = ya_push(out, ys("/' -e 's/$$/"));/' src/y/std/prof.y; \
	  echo '    out = ya_push(out, ys(""));'; \
	  echo '    return out;'; \
	  echo '}'; } > $@

# [2/3] the C copy compiles the compiler -> ycc (native static ELF, no
# toolchain). [3/3] acceptance: ycc must be byte-identical to the backed-up
# reference binary — that is the C copy validated against the real ycc —
# and to its own self-compile (fixpoint).
ycc: cycc $(YCC_SRCS) $(CYC_SRCS) $(CY_HDRS)
	./cycc -o ycc src/y/ycc.y
	cmp ycc refs/ycc.ref
	./ycc -o _ycc src/y/ycc.y
	cmp ycc _ycc
	rm -f _ycc
	@echo "verified: cycc output == refs/ycc.ref == ycc self-compile (byte-identical)"

# AddressSanitizer + UBSan build of the C copy (one command, no CI).
ASAN_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g

cycc-asan: $(CYC_SRCS) $(CY_HDRS)
	$(GCC) $(CFLAGS) $(ASAN_FLAGS) -o cycc-asan $(CYC_SRCS)

asan: cycc-asan

test-asan: cycc-asan
	YCC=$(CURDIR)/cycc-asan ASAN_OPTIONS=detect_leaks=0 \
	    ./test/sh/run_all.sh $(SUITES_ASAN)

# Full suite (see test/sh/). Suites compare the C copy's output against
# the reference ycc and run the compiled programs.
test: ycc
	./test/sh/run_all.sh $(SUITES)

test-fast: cycc
	./test/sh/run_all.sh $(SUITES)

# Tiny smoke test: compile + run one example with both compilers.
test-compile: cycc ycc
	./cycc -o /tmp/hello_c test/y/examples/helloworld.y && /tmp/hello_c
	./ycc -o /tmp/hello_y test/y/examples/helloworld.y && /tmp/hello_y

clean:
	rm -f $(CYC_SRCS:src/c/%.c=src/c/%.o) cycc cycc-asan ycc _ycc a.out
	rm -f $(PROF_LINES_C) $(STD_LINES_C)

valgrind: cycc
	valgrind --leak-check=full --quiet ./cycc

.PHONY: all clean valgrind test test-fast test-compile asan test-asan ycc
