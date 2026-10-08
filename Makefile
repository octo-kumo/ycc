# y compiler. AGENTS.md has the workflow; `make help` lists the targets.
#
# cycc is the C copy of the compiler (src/c, a 1:1 port of src/y, PORTING.md);
# ycc is the Y compiler, built by cycc, with the std pack attached and checked
# byte-for-byte against refs/ycc.ref.

GCC     = gcc
# -O1: the suites compile their whole corpus with cycc as well, and -O0 doubles
# that; -O2 builds slower than it saves.
CFLAGS  = -Wall -Wextra -std=gnu99 -O1 -g
CYC_SRCS = $(wildcard src/c/*.c)
CY_HDRS  = $(wildcard src/c/*.h)

# Every recipe line runs under an address-space cap below 4 GB (this machine
# goes down past it); test/sh/capped.sh sets it. A memory regression then fails
# a build with "out of memory" instead of taking the machine. cycc needs about
# 1.9 GB for ycc.y, ycc about 1.1 GB; ASan reserves terabytes, so it is capped
# by RSS instead.
SHELL      := $(CURDIR)/test/sh/capped.sh
CYCC_MEM_KB = 3670016
YCC_MEM_KB  = 2097152
ASAN_RSS_MB = 3500

YCC_SRCS = $(wildcard src/y/*.y) src/y/std/fs.y src/y/std/net.y src/y/std/struct.y \
           src/y/std/prelude.y src/y/std/exec.y src/y/std/rt.y src/y/std/str.y src/y/std/kernel.y
# Nothing is embedded in the compiler: std units and the runtime assembly are
# compiled into the pack attached to ycc, so an edit to any of them rebuilds
# every packed binary. cycc and a bootstrap generation read them from disk.
STD_SRCS  = $(wildcard src/y/std/*.y)
ARCH_SRCS = $(wildcard src/y/arch/*.s)
LSP_SRC   = $(wildcard src/tools/lsp/*.y)
OS_SRCS   = $(wildcard os/kernel/*.y os/uland/*.y os/tools/*.y)

JOBS ?= $(shell nproc)
# BASE and NEW are the two compilers `check`, `corpus-diff` and the benchmarks
# compare. YREF is the blessed reference the suites call.
BOOT ?= refs/ycc.ref
BASE ?= refs/ycc.ref
NEW  ?= ./ynew
YREF ?= $(CURDIR)/refs/ycc.ref
NEW_DEP = $(if $(filter ./ynew ynew,$(NEW)),ynew)

# $(call PACK,BIN,OUT): OUT = BIN with its std pack attached.
PACK = ./$(1) --std-pack $(2).pack && cat $(1) $(2).pack > $(2) && chmod 755 $(2) && rm -f $(2).pack
# $(call CAP,KB): run the rest of the line under a memory cap.
CAP  = ulimit -v $(1);

all: cycc

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

## ── build ────────────────────────────────────────────────────────────────
## cycc        the C copy of the compiler
cycc: $(CYC_SRCS) $(CY_HDRS)
	$(GCC) $(CFLAGS) -o cycc $(CYC_SRCS)
	@echo "cycc built: the C copy of the compiler ($$(stat -c%s cycc) bytes)"

## ycc         cycc builds the compiler; the pack is attached; it must equal
##             refs/ycc.ref and rebuild itself (the acceptance gate)
ycc: cycc $(YCC_SRCS) $(CYC_SRCS) $(CY_HDRS) $(STD_SRCS) $(ARCH_SRCS)
	$(call CAP,$(CYCC_MEM_KB)) ./cycc -o _ycc0 src/y/ycc.y
	$(call PACK,_ycc0,ycc)
	cmp ycc refs/ycc.ref
	$(call CAP,$(YCC_MEM_KB)) ./ycc -o _ycc src/y/ycc.y
	cmp _ycc0 _ycc
	rm -f _ycc _ycc0
	@echo "verified: cycc output == refs/ycc.ref == ycc self-compile (byte-identical)"

## ynew        src/y built by BOOT, then twice by itself (generations 2 and 3
##             must be identical); needs no C port
ynew: $(YCC_SRCS) $(BOOT) $(STD_SRCS) $(ARCH_SRCS)
	$(call CAP,$(YCC_MEM_KB)) $(abspath $(BOOT)) -o _ynew1 src/y/ycc.y
	$(call CAP,$(YCC_MEM_KB)) ./_ynew1 -o _ynew2 src/y/ycc.y
	$(call PACK,_ynew2,_ynewp)
	$(call CAP,$(YCC_MEM_KB)) ./_ynewp -o _ynew3 src/y/ycc.y
	cmp _ynew2 _ynew3
	mv _ynewp ynew
	rm -f _ynew1 _ynew2 _ynew3
	@echo "ynew built from src/y by $(BOOT): generations 2 and 3 are byte-identical"

## yserve      the language server; both compilers must build it identically
yserve: $(LSP_SRC) $(STD_SRCS) $(ARCH_SRCS) cycc
	@rm -f yserve _yserve0 _yserve1 _yserve1p
	$(call CAP,$(CYCC_MEM_KB)) ./cycc -o _yserve0 src/tools/lsp/yserve.y
	$(call PACK,_yserve0,yserve)
	$(call CAP,$(CYCC_MEM_KB)) $(YREF) -o _yserve1 src/tools/lsp/yserve.y
	$(call PACK,_yserve1,_yserve1p)
	@if cmp -s yserve _yserve1p; then \
	  echo "verified: cycc output == $(YREF) output == yserve (byte-identical)"; \
	else \
	  echo "yserve: cycc and $(YREF) DISAGREE. yserve imports the compiler's own"; \
	  echo "  modules, so a C/Y divergence shows up here first; run 'make port-check'."; \
	  rm -f _yserve0 _yserve1 _yserve1p; exit 1; \
	fi
	@rm -f _yserve0 _yserve1 _yserve1p

## ytest       the test runner and the development tools, written in Y
##             (src/tools/ytest; `./ytest help`); cycc builds it
YTEST_SRCS = $(wildcard src/tools/ytest/*.y)
ytest: cycc $(YTEST_SRCS) $(STD_SRCS)
	$(call CAP,$(CYCC_MEM_KB)) ./cycc -o ytest src/tools/ytest/ytest.y

## cycc.exe    the C copy cross-built for Windows (gate: ./ytest cycc-win)
MINGW ?= x86_64-w64-mingw32-gcc
cycc.exe: $(CYC_SRCS) $(CY_HDRS)
	$(MINGW) $(CFLAGS) -o cycc.exe $(CYC_SRCS)

## os          Y-OS image and filesystem in os/build/; run-os boots it
os/build/os.img os/build/os.fs: ycc ytest $(OS_SRCS) $(STD_SRCS)
	./ytest os-build ./ycc
os: os/build/os.img
run-os: os
	./ytest os-run

## ── the development loop ─────────────────────────────────────────────────
## check       C copy builds NEW byte for byte, every suite passes, then NEW
##             is compared with BASE (programs, instruction counts, timings)
check: cycc ytest $(NEW_DEP)
	./ytest check $(BASE) $(NEW) $(or $(ROUNDS),3)

## rebless     accept the C copy's build as refs/ycc.ref (and ./ycc), once it
##             rebuilds itself and passes both halves of the port gate
rebless: cycc ytest
	$(call CAP,$(CYCC_MEM_KB)) ./cycc -o _rb1 src/y/ycc.y
	$(call CAP,$(YCC_MEM_KB)) ./_rb1 -o _rb2 src/y/ycc.y
	cmp _rb1 _rb2
	$(call PACK,_rb1,_rbp)
	YREF=$(CURDIR)/_rbp YQUIET=1 YPORT_SELF=0 ./ytest -j $(JOBS) port pe-port
	cp _rbp refs/ycc.ref
	cd refs && sha256sum *.ref > SHA256SUMS
	mv _rbp ycc
	rm -f _rb1 _rb2
	@echo "blessed refs/ycc.ref $$(sha256sum refs/ycc.ref | cut -c1-16)"

## port-check  the C copy against ./ynew (lists only programs that differ)
port-check: cycc ytest ynew
	YREF=$(CURDIR)/ynew YQUIET=1 ./ytest -j $(JOBS) port

## corpus-diff programs in test/y and src/y/ycc.y (or FILES="a.y b.y") that
##             BASE and NEW compile differently
corpus-diff: ytest $(NEW_DEP)
	./ytest corpus-diff $(BASE) $(NEW) $(FILES)

## bench       timings of BASE against NEW (ROUNDS pairs, default 5)
## bench-ir    exact instruction counts of the compiles
bench: ytest $(NEW_DEP)
	./ytest bench $(BASE) $(NEW) $(or $(ROUNDS),5)
bench-ir: ytest $(NEW_DEP)
	./ytest bench-ir $(BASE) $(NEW)

## ── tests (./ytest; SUITES="port native" narrows, ./ytest list names them) ─
## test        every suite, with the built ./ycc
## test-fast   the same with only ./cycc (the suites that need ./ycc skip)
test: ycc ytest
	YPORT_SELF=0 ./ytest -j $(JOBS) $(SUITES)
test-fast: cycc ytest
	./ytest -j $(JOBS) $(SUITES)

## test-compile  compile and run one example with both compilers
test-compile: cycc ycc
	@d=$$(mktemp -d -t ycc-hello.XXXXXX) && \
	  ./cycc -o $$d/c test/y/examples/helloworld.y && $$d/c && \
	  ./ycc -o $$d/y test/y/examples/helloworld.y && $$d/y; rc=$$?; rm -rf $$d; exit $$rc

## asan / test-asan   sanitized cycc (every finding fatal) and the suites on it
ASAN_FLAGS = -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g
cycc-asan: $(CYC_SRCS) $(CY_HDRS)
	$(GCC) $(CFLAGS) $(ASAN_FLAGS) -o cycc-asan $(CYC_SRCS)
asan: cycc-asan
test-asan: cycc-asan ytest
	CYCC=$(CURDIR)/cycc-asan YCC=$(CURDIR)/cycc-asan ASAN_OPTIONS=detect_leaks=0:hard_rss_limit_mb=$(ASAN_RSS_MB) \
	    ./ytest $(SUITES_ASAN)

## valgrind    memcheck errors (not leaks: the value model never frees)
valgrind: cycc
	@d=$$(mktemp -d -t cycc-vg.XXXXXX) && \
	  valgrind --error-exitcode=1 --quiet ./cycc -o $$d/out test/y/examples/helloworld.y; rc=$$?; rm -rf $$d; exit $$rc

## asm-check   GNU as reads src/y/arch/*.s (fragments, so `$a-b` length
##             immediates are normalised first; undefined labels are not its job)
asm-check:
	@command -v as >/dev/null 2>&1 || { echo "asm-check: no GNU as, skipped"; exit 0; }
	@d=$$(mktemp -d -t asm-check.XXXXXX); rc=0; for f in $(ARCH_SRCS); do \
	    sed -E 's/\$$[A-Za-z_0-9]+-[A-Za-z_0-9]+/$$0/g' $$f > $$d/a.s; \
	    if as -o /dev/null $$d/a.s 2>$$d/err; then echo "  ok   $$f"; \
	    else echo "  FAIL $$f"; sed 's/^/    /' $$d/err; rc=1; fi; \
	  done; rm -rf $$d; \
	  if [ $$rc = 0 ]; then echo "asm-check: GNU as reads every arch .s file"; fi; exit $$rc

## ── formatting, language server, docs ────────────────────────────────────
## fmt         format src/y, src/y/std and src/tools/lsp in place
## fmt-check   idempotence over the tree (the gate) + the fixed-point count
fmt: cycc ytest
	./ytest fmt
fmt-check: cycc ytest
	./ytest fmt-check

## lsp-ext / lsp-vsix / lsp-e2e   the VS Code extension (needs node), its
##             package, and the server driven as a process
lsp-ext:
	cd src/tools/lsp/vscode-y-lang && \
	  { [ -f package-lock.json ] && npm ci || npm install; } && npm run compile
lsp-vsix: lsp-ext
	cd src/tools/lsp/vscode-y-lang && \
	  npx -y @vscode/vsce package --no-git-tag-version --allow-missing-repository
lsp-e2e: ycc ytest
	./ytest lsp-e2e

## docs        the manual, docs/build/manual.pdf (needs tectonic; fails on any
##             LaTeX error or over/underfull box)
DOC_OUT = docs/build
DOC_PDF = $(DOC_OUT)/manual.pdf
DOC_LOG = $(DOC_OUT)/manual.log
docs: $(DOC_PDF)
$(DOC_PDF): $(wildcard docs/src/*.tex) docs/Tectonic.toml
	@command -v tectonic >/dev/null 2>&1 || { echo "make docs: no tectonic, skipped"; exit 0; }
	@mkdir -p $(DOC_OUT)
	cd docs/src && (cat _preamble.tex index.tex _postamble.tex \
	    | tectonic --outdir $(CURDIR)/$(DOC_OUT) --keep-logs -) \
	  || { echo "make docs: tectonic failed; its diagnostics are above"; exit 1; }
	@mv $(DOC_OUT)/texput.pdf $(DOC_PDF)
	@mv $(DOC_OUT)/texput.log $(DOC_LOG)
	@! grep -q '^! ' $(DOC_LOG) || { echo "make docs: LaTeX errors, see $(DOC_LOG)"; exit 1; }
	@! grep -qE '^(Overfull|Underfull) \\hbox' $(DOC_LOG) || { echo "make docs: over/underfull \\hbox, see $(DOC_LOG)"; exit 1; }
	@echo "manual: $(DOC_PDF) ($$(stat -c%s $(DOC_PDF)) bytes), no errors and no warnings"

clean:
	rm -f $(CYC_SRCS:src/c/%.c=src/c/%.o) cycc cycc.exe cycc-asan ycc ynew ytest a.out
	rm -f _ycc _ycc0 _ycc0.pack ycc.pack _ynew1 _ynew2 _ynew3 _ynewp _ynewp.pack _rb1 _rb2 _rbp _rbp.pack
	rm -rf _check docs/build

.PHONY: all help clean valgrind test test-fast test-compile asan test-asan asm-check ycc yserve \
        lsp-ext lsp-vsix lsp-e2e check port-check corpus-diff bench bench-ir rebless docs os run-os fmt fmt-check
