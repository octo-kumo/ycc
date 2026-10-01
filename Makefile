GCC=gcc
# The C compiler is a 1:1 copy of the Y compiler (see PORTING.md): it compiles .y straight to a native ELF exactly like ycc.
CFLAGS=-Wall -Wextra -std=gnu99 -g
CYC_SRCS=$(wildcard src/c/*.c)
CY_HDRS=$(wildcard src/c/*.h)
CYCC=cycc

# The Y compiler sources: what the compiler compiles (and mirrors in C).
YCC_SRCS=src/y/ycc.y src/y/lexer.y src/y/parser.y src/y/types.y src/y/native.y src/y/arch_x64.y src/y/rename.y src/y/enc64.y src/y/asm.y src/y/elf.y src/y/std/io.y src/y/std/net.y src/y/std/struct.y src/y/std/prelude.y src/y/std/exec.y src/y/std/rt.y src/y/std/str.y

# The std files the compiler splices into programs, embedded into it when
# it is built: native.y says `embed RT_SRC from "./std/rt.y";`, the C copy
# Y_EMBED(...) — an .incbin, so the C build reads them too (from the repo
# root, where these rules run gcc).
STD_EMBEDS=src/y/std/rt.y src/y/std/prelude.y src/y/std/exec.y src/y/std/str.y

all: cycc

# [1/3] gcc builds the C copy of the compiler.
cycc: $(CYC_SRCS) $(CY_HDRS) $(STD_EMBEDS)
	$(GCC) $(CFLAGS) -o cycc $(CYC_SRCS)
	@echo "cycc built: the C copy of the compiler ($$(stat -c%s cycc) bytes)"

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

# AddressSanitizer + UBSan build of the C copy (one command, no CI). Every
# finding is fatal (-fno-sanitize-recover): UBSan's default is to print and
# carry on, and a suite that compares outputs never sees a report it printed.
ASAN_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g

cycc-asan: $(CYC_SRCS) $(CY_HDRS) $(STD_EMBEDS)
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
# the reference ycc and run the compiled programs, JOBS at a time (the long
# ones in shards); each one's output is printed whole once all are done,
# JOBS=1 runs them one by one with live output. Building ./ycc was the port
# gate on src/y/ycc.y itself, so the port suite leaves it out (YPORT_SELF=0).
JOBS ?= $(shell nproc)
test: ycc
	YPORT_SELF=0 ./test/sh/run_all.sh -j $(JOBS) $(SUITES)

# Same suites without the acceptance gate: only ./cycc is built, so the five
# suites that drive a built ./ycc (ycc, fixpoint, native, native-examples,
# debug) announce themselves as skipped. Use for a quick signal; `make test` is
# the real one.
test-fast: cycc
	./test/sh/run_all.sh -j $(JOBS) $(SUITES)

# Tiny smoke test: compile + run one example with both compilers.
test-compile: cycc ycc
	./cycc -o /tmp/hello_c test/y/examples/helloworld.y && /tmp/hello_c
	./ycc -o /tmp/hello_y test/y/examples/helloworld.y && /tmp/hello_y

# ── The development loop (AGENTS.md, "Changing the compiler") ────────────
# A change lands in src/y and, the same, in src/c. `make check` verifies it
# and measures it against BASE in a few minutes; `make rebless` accepts it
# as the new reference. The steps `check` is made of, to run on their own:
# `make ynew` builds src/y and checks it rebuilds itself (no C port needed),
# `make port-check` holds the C copy to it, `make corpus-diff` shows what
# it changes, `make bench` and `make bench-ir` measure it. BASE (default:
# refs/ycc.ref, the last blessed compiler) is compared with NEW (default:
# ./ynew, built first when it is the one compared).
BOOT ?= refs/ycc.ref
BASE ?= refs/ycc.ref
NEW ?= ./ynew
NEW_DEP = $(if $(filter ./ynew ynew,$(NEW)),ynew)

# ./ynew: src/y compiled by BOOT, then by itself twice. A change to the
# emitter reaches the compiler's own code in the second generation, so the
# second and third must be byte-identical (the fixpoint). Needs no C port.
ynew: $(YCC_SRCS) $(BOOT)
	ulimit -v $(YCC_MEM_KB); $(abspath $(BOOT)) -o _ynew1 src/y/ycc.y
	ulimit -v $(YCC_MEM_KB); ./_ynew1 -o _ynew2 src/y/ycc.y
	ulimit -v $(YCC_MEM_KB); ./_ynew2 -o _ynew3 src/y/ycc.y
	cmp _ynew2 _ynew3
	mv _ynew2 ynew
	rm -f _ynew1 _ynew3
	@echo "ynew built from src/y by $(BOOT): generations 2 and 3 are byte-identical"

# Everything a change needs before `make rebless`, in one command and a few
# minutes (test/sh/check.sh): the C copy must build NEW byte for byte and
# every suite pass with it; then what it changes against BASE — the test
# programs it compiles differently, instruction counts compiling and
# running the benchmarks, and timings (ROUNDS pairs of runs per row at
# least, default 3). A summary on screen, each step's full output in
# _check/.
check: cycc $(NEW_DEP)
	./test/sh/check.sh $(BASE) $(NEW) $(or $(ROUNDS),3)

# The C copy against the Y build: the port gate (test_port.sh) aimed at
# ./ynew instead of refs/ycc.ref. Lists only the programs that differ.
port-check: cycc ynew
	YREF=$(CURDIR)/ynew YQUIET=1 ./test/sh/run_all.sh -j $(JOBS) port

# Every program in test/y/ and src/y/ycc.y (or FILES="a.y b.y") compiled by
# BASE and NEW: lists each whose exit code, messages or binary differ, and
# runs each changed binary under both to tell new code from new behavior.
corpus-diff: $(NEW_DEP)
	./test/sh/corpus_diff.sh $(BASE) $(NEW) $(FILES)

# Benchmarks (bench/README.md): timings (ROUNDS pairs of runs per row at
# least, default 5) and per-function run profiles; bench-ir: exact
# instruction counts of the compiles. bench times copies of the two
# compilers under /tmp: under WSL a binary run from /mnt/c pages in through
# drvfs and runs ~30% slower.
bench: $(NEW_DEP)
	@d=$$(mktemp -d /tmp/ybench-bin.XXXXXX) && cp $(BASE) $$d/base && cp $(NEW) $$d/new \
	  && echo "bench: base = $(BASE), new = $(NEW)" \
	  && bench/compare.sh $$d/base $$d/new $(or $(ROUNDS),5); rc=$$?; rm -rf $$d; exit $$rc

bench-ir: $(NEW_DEP)
	bench/compile_ir.sh $(BASE) $(NEW)

# Accept the C copy's build of the compiler as refs/ycc.ref, once it
# rebuilds itself byte-identically and passes the port gate (on every test
# program; on ycc.y it is that build); it becomes ./ycc too. Run `make
# check` first: it runs every suite on this same build.
rebless: cycc
	ulimit -v $(CYCC_MEM_KB); ./cycc -o _rb1 src/y/ycc.y
	ulimit -v $(YCC_MEM_KB); ./_rb1 -o _rb2 src/y/ycc.y
	cmp _rb1 _rb2
	YREF=$(CURDIR)/_rb1 YQUIET=1 YPORT_SELF=0 ./test/sh/run_all.sh -j $(JOBS) port
	cp _rb1 refs/ycc.ref
	cd refs && sha256sum *.ref > SHA256SUMS
	mv _rb1 ycc
	rm -f _rb2
	@echo "blessed refs/ycc.ref $$(sha256sum refs/ycc.ref | cut -c1-16)"

clean:
	rm -f $(CYC_SRCS:src/c/%.c=src/c/%.o) cycc cycc-asan ycc _ycc a.out
	rm -f ynew _ynew1 _ynew2 _ynew3 _rb1 _rb2
	rm -rf _check

# Memcheck the C copy on a real input. NOTE: no --leak-check=full: the Y
# value model (src/c/yv.c) never frees, so a leak gate could never be clean
# and the target would fail for the wrong reason. We gate on memcheck
# ERRORS (invalid reads/writes, uninitialised values), which is what can
# actually regress.
valgrind: cycc
	valgrind --error-exitcode=1 --quiet ./cycc -o /tmp/cycc-vg test/y/examples/helloworld.y

.PHONY: all clean valgrind test test-fast test-compile asan test-asan ycc check port-check corpus-diff bench bench-ir rebless
