GCC=gcc
# The C compiler is a 1:1 copy of the Y compiler (see PORTING.md): it compiles .y straight to a native ELF exactly like ycc.
CFLAGS=-Wall -Wextra -std=gnu99 -g
CYC_SRCS=$(wildcard src/c/*.c)
CY_HDRS=$(wildcard src/c/*.h)
CYCC=cycc

# The Y compiler sources: what the compiler compiles (and mirrors in C).
YCC_SRCS=src/y/ycc.y src/y/lexer.y src/y/parser.y src/y/types.y src/y/native.y src/y/arch_x64.y src/y/rename.y src/y/enc64.y src/y/asm.y src/y/elf.y src/y/std/io.y src/y/std/net.y src/y/std/struct.y src/y/std/prelude.y src/y/std/rt.y

# The std modules embed their own source as line arrays (the shipped ycc
# is a standalone ELF); the C copy gets generated twins of those arrays.
STD_LINES_C=src/c/std_lines.c

all: cycc

# [1/3] gcc builds the C copy of the compiler.
cycc: $(CYC_SRCS) $(CY_HDRS) $(STD_LINES_C)
	$(GCC) $(CFLAGS) -o cycc $(CYC_SRCS)
	@echo "cycc built: the C copy of the compiler ($$(stat -c%s cycc) bytes)"

$(STD_LINES_C): tools/gen_std_lines.py src/y/std/rt.y src/y/std/prelude.y
	python3 tools/gen_std_lines.py $@ src/y/std/rt.y:rt_lines \
	    src/y/std/prelude.y:prelude_lines src/y/std/prelude.y:exec_lines \
	    src/y/std/prelude.y:prelude_names src/y/std/prelude.y:exec_names

# [2/3] the C copy compiles the compiler -> ycc (native static ELF, no
# toolchain). [3/3] acceptance: ycc must be byte-identical to the backed-up
# reference binary — that is the C copy validated against the real ycc —
# and to its own self-compile (fixpoint).
# Both compiles run under a virtual-memory cap (ulimit -v, in KB), so a memory
# regression fails the build ("out of memory") instead of swapping the
# machine: cycc needs ~4.1 GB for ycc.y, ycc itself ~0.8 GB.
CYCC_MEM_KB=6291456
YCC_MEM_KB=2097152
ycc: cycc $(YCC_SRCS) $(CYC_SRCS) $(CY_HDRS)
	ulimit -v $(CYCC_MEM_KB); ./cycc -o ycc src/y/ycc.y
	cmp ycc refs/ycc.ref
	ulimit -v $(YCC_MEM_KB); ./ycc -o _ycc src/y/ycc.y
	cmp ycc _ycc
	rm -f _ycc
	@echo "verified: cycc output == refs/ycc.ref == ycc self-compile (byte-identical)"

# AddressSanitizer + UBSan build of the C copy (one command, no CI).
ASAN_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g

cycc-asan: $(CYC_SRCS) $(CY_HDRS)
	$(GCC) $(CFLAGS) $(ASAN_FLAGS) -o cycc-asan $(CYC_SRCS)

asan: cycc-asan

# The suites read the compiler they test from the environment: $CYCC (lib.sh,
# ytool.sh — the C copy) and $YCC (the suites that drive a built ./ycc). Both
# must name cycc-asan, or the sanitized build is never exercised at all.
# $YREF stays refs/ycc.ref: the golden reference is deliberately unsanitized,
# and it is what the sanitized build's bytes are compared against.
# Suites that need ./ycc (ycc, fixpoint, native, native-examples, debug) skip
# themselves unless it is built; SUITES_ASAN is normally a subset, since a
# sanitized self-compile wants orders of magnitude more memory than a plain one.
test-asan: cycc-asan
	CYCC=$(CURDIR)/cycc-asan YCC=$(CURDIR)/cycc-asan ASAN_OPTIONS=detect_leaks=0 \
	    ./test/sh/run_all.sh $(SUITES_ASAN)

# Full suite (see test/sh/). Suites compare the C copy's output against
# the reference ycc and run the compiled programs.
test: ycc
	./test/sh/run_all.sh $(SUITES)

# Same suites without the acceptance gate: only ./cycc is built, so the five
# suites that drive a built ./ycc (ycc, fixpoint, native, native-examples,
# debug) announce themselves as skipped. Use for a quick signal; `make test` is
# the real one.
test-fast: cycc
	./test/sh/run_all.sh $(SUITES)

# Tiny smoke test: compile + run one example with both compilers.
test-compile: cycc ycc
	./cycc -o /tmp/hello_c test/y/examples/helloworld.y && /tmp/hello_c
	./ycc -o /tmp/hello_y test/y/examples/helloworld.y && /tmp/hello_y

# The generated file goes too; make regenerates it (src/c/std_lines.c is
# committed — regenerating it is byte-identical, so a clean rebuild leaves
# no diff).
clean:
	rm -f $(CYC_SRCS:src/c/%.c=src/c/%.o) cycc cycc-asan ycc _ycc a.out
	rm -f $(STD_LINES_C)

# Memcheck the C copy on a real input. NOTE: no --leak-check=full: the Y
# value model (src/c/yv.c) never frees, so a leak gate could never be clean
# and the target would fail for the wrong reason. We gate on memcheck
# ERRORS (invalid reads/writes, uninitialised values), which is what can
# actually regress.
valgrind: cycc
	valgrind --error-exitcode=1 --quiet ./cycc -o /tmp/cycc-vg test/y/examples/helloworld.y

.PHONY: all clean valgrind test test-fast test-compile asan test-asan ycc
