GCC=gcc
# runtime.c/h live in src/c; codegen -I and the compiled-program link both
# resolve the runtime there via RUNTIME_DIR.
CFLAGS=-Wall -Wextra -std=gnu99 -g -DRUNTIME_DIR='"$(CURDIR)/src/c"'
SRCS=$(wildcard src/c/*.c)
HDRS=$(wildcard src/c/*.h)
OBJS=$(SRCS:src/c/%.c=src/c/%.o)
YBOOT=yboot

# Stage names:
#   yboot = src/c compiler built by gcc: parses Y, runs the VM, emits C.
#           No native backend — it cannot produce assembly.
#   cycc  = ycc compiled by yboot (C emission + cc + runtime.c): a full
#           ycc with the native backend.
#   ycc   = ycc compiled by cycc, natively (static ELF bytes, no toolchain).
#   _ycc  = ycc compiled by ycc; must be byte-identical to ycc, then deleted.
# Bootstrap chain: yboot -> cycc -> ycc -> _ycc (fixpoint check).
YCC_SRCS=src/y/ycc.y src/y/lexer.y src/y/parser.y src/y/types.y src/y/native.y src/y/arch_x64.y src/y/rename.y src/y/enc64.y src/y/asm.y src/y/elf.y src/y/std/io.y

all: $(YBOOT)

$(YBOOT): $(OBJS)
	$(GCC) $(CFLAGS) -o $@ $^

src/c/%.o: src/c/%.c $(HDRS)
	$(GCC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(YBOOT) cycc ycc _ycc a.out

valgrind: $(YBOOT)
	valgrind --leak-check=full --quiet ./yboot

# Full suite: build the whole compiler chain (yboot -> cycc -> ycc), then
# run every test/sh/*.sh suite. The native suite runs against the fixpoint
# `ycc` binary.
test: $(YBOOT) ycc
	./test/sh/run_all.sh $(SUITES)

# Fast suite: everything except the ycc chain (ycc / native suites
# self-skip when ./ycc is absent). Use for iteration.
test-fast: $(YBOOT)
	./test/sh/run_all.sh $(SUITES)

# Self-hosted check only (builds the full chain, then runs it).
test-ycc: ycc
	./test/sh/test_ycc.sh

# Tiny smoke test: compile + run one example.
test-compile: $(YBOOT)
	./yboot --compile test/y/examples/helloworld.y -o /tmp/hello_bin && /tmp/hello_bin

# [1/4] gcc builds src/c -> yboot (VM + C emission only).

# [2/4] yboot compiles ycc -> cycc (emitted C, cc-linked with runtime.c).
# Incremental: only rebuilt when yboot or any Y source is newer. The
# bootstrap (yboot C emission) is the slowest step, so it must not re-run
# on unrelated invocations — the bootstrapped binaries are kept.
cycc: $(YBOOT) $(YCC_SRCS) src/c/runtime.c src/c/runtime.h
	./yboot -S -o /tmp/ycc_boot.c src/y/ycc.y
	$(GCC) -O2 -std=gnu99 -Isrc/c -o cycc /tmp/ycc_boot.c src/c/runtime.c -lm
	@echo "stage-2: ./cycc built by yboot via C emission ($$(stat -c%s cycc) bytes)"

# [3/4] cycc compiles ycc -> ycc (native static ELF, no toolchain).
# [4/4] ycc compiles ycc -> _ycc; cmp must be byte-identical; rm _ycc.
# The fixpoint check runs whenever the chain rebuilds; a no-op build keeps
# the existing (already verified) ycc untouched.
ycc: cycc
	./cycc -o ycc src/y/ycc.y
	@echo "stage-3: ./ycc built by cycc, natively ($$(stat -c%s ycc) bytes)"
	./ycc -o _ycc src/y/ycc.y
	@echo "stage-4: _ycc built by ycc"
	cmp ycc _ycc
	rm -f _ycc
	@echo "fixpoint verified: ycc == _ycc (byte-identical) — ycc compiled by ycc"


.PHONY: all clean valgrind test test-fast test-ycc test-compile
