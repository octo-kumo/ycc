# y compiler. AGENTS.md has the workflow; `make help` lists the targets.
#
# cycc is the generated C seed (bootstrap/ycc.c); ycc is built from current
# Y sources by that seed, carries its std pack and must reproduce itself.

GCC     = gcc
# Every recipe line runs under an address-space cap below 4 GB;
# test/sh/capped.sh sets it. A memory regression then fails a build with
# "out of memory" instead of taking the machine. The self-build needs about
# 2.1 GB; 3 GiB is its budget. ASan reserves terabytes, so it is capped by RSS
# instead.
SHELL      := $(CURDIR)/test/sh/capped.sh
CYCC_MEM_KB = 3670016
YCC_MEM_KB  = 3145728
ASAN_RSS_MB = 3500

YCC_SRCS = $(wildcard src/y/*.y) src/y/std/fs.y src/y/std/net.y src/y/std/struct.y \
           src/y/std/prelude.y src/y/std/exec.y src/y/std/rt.y src/y/std/str.y src/y/std/kernel.y
# Nothing is embedded in the compiler: std units and the runtime assembly are
# compiled into the pack attached to ycc, so an edit to any of them rebuilds
# every packed binary. cycc and a bootstrap generation read them from disk.
STD_SRCS  = $(wildcard src/y/std/*.y) src/y/std/gui.font
ARCH_SRCS = $(wildcard src/y/arch/*.s)
# The JavaScript host: concatenated into the pack's web.host entry,
# so an edit under src/web rebuilds every packed binary.
WEB_SRCS  = $(wildcard src/web/*.js src/web/*.json src/web/*.html src/web/*.css)
LSP_SRC   = $(wildcard src/tools/lsp/*.y)
OS_SRCS   = $(wildcard os/kernel/*.y os/uland/*.y os/tools/*.y os/assets/font8x16.bin os/assets/wallpaper.yvg)

JOBS ?= $(shell nproc)
# Bound the whole development bless, including recursive make prerequisites.
REBLESS_TIMEOUT ?= 60
REBLESS_FULL_TIMEOUT ?= 120
# BASE and NEW are the two compilers `check`, `corpus-diff` and the benchmarks
# compare. YREF is the blessed reference the suites call.
BOOT ?= refs/ycc.ref
BASE ?= refs/ycc.ref
NEW  ?= ./ynew
YREF ?= $(CURDIR)/refs/ycc.ref
NEW_DEP = $(if $(filter ./ynew ynew,$(NEW)),ynew)

# $(call PACK,BIN,OUT): OUT = BIN with its std pack attached.
PACK = ./$(1) --std-pack $(2).pack && cat $(1) $(2).pack > $(2) && chmod 755 $(2) && rm -f $(2).pack
# $(call PACKSTUB,BIN,OUT): OUT = BIN with the pack stub AND the std pack,
# framed as base || STUB || LEN8 || "YCCSTUB1" || stdpack || LEN8 || "YCCPACK1".
# STUB bundles x86-64 and AArch64 executables as YCCSTB2! || LEN8 || x86 || arm.
# Each stub is src/y/packstub.y compiled by BIN itself; the std pack keeps the
# last 16 bytes so self_pack and --std-pack are untouched. Only a compiler that
# can --pack carries one (ycc, ynew, the rebless artifact).
PACKSTUB = ./$(1) --target=linux --gc=never -o $(2).xstub src/y/packstub.y && ./$(1) --target=linux --arch=aarch64 --gc=never -o $(2).astub src/y/packstub.y && printf 'YCCSTB2!%08d' $$(stat -c%s $(2).xstub) > $(2).stub && cat $(2).xstub $(2).astub >> $(2).stub && ./$(1) --std-pack $(2).pack && n=$$(stat -c%s $(2).stub) && printf '%08dYCCSTUB1' $$n > $(2).stub.len && cat $(if $(3),$(3),$(1)) $(2).stub $(2).stub.len $(2).pack > $(2) && chmod 755 $(2) && rm -f $(2).pack $(2).stub $(2).stub.len $(2).xstub $(2).astub
# $(call CAP,KB): run the rest of the line under a memory cap.
CAP  = ulimit -v $(1);

all: cycc

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

## ── build ────────────────────────────────────────────────────────────────
# The generated seed links only the value and host runtime.
BOOT_RUNTIME = src/c/yv.c src/c/host.c
BOOT_HEADERS = src/c/yv.h src/c/host.h src/c/ylong.h tools/bootstrap/runtime.h tools/bootstrap/gc.h
BOOT_FLAGS = -std=gnu99 -O1 -g -DYV_GC -include tools/bootstrap/gc.h -Itools/bootstrap -Isrc/c
BOOT_LIBS = -l:libgc.so.1 -lm

## cycc        GCC builds the generated C seed (requires libgc.so.1)
cycc: bootstrap/ycc.c $(BOOT_RUNTIME) $(BOOT_HEADERS)
	$(GCC) $(BOOT_FLAGS) bootstrap/ycc.c $(BOOT_RUNTIME) $(BOOT_LIBS) -o cycc
	@echo "cycc built from generated C ($$(stat -c%s cycc) bytes)"

## c-bootstrap generate a hosted C compiler from Y (experimental, not the default)
## c-bootstrap-test compare the C backend's supported constructs with native Y
## c-bootstrap-smoke also build and run Hello World through the generated compiler
## c-bootstrap-gc build the generated compiler with the installed libgc.so.1 collector
## bootstrap-update refresh the checked-in C seed and its Y source manifest
_check/bootstrap.c: ynew tools/bootstrap-c.py $(wildcard tools/bootstrap/*.py tools/bootstrap/*.h)
	mkdir -p _check
	python3 tools/bootstrap-c.py src/y/ycc.y -o $@ --compiler ./ynew

c-bootstrap: _check/bootstrap.c
	$(GCC) -std=gnu99 -O1 -g -Itools/bootstrap -Isrc/c _check/bootstrap.c $(BOOT_RUNTIME) -lm -o _check/cycc-generated

c-bootstrap-gc: _check/bootstrap.c
	$(GCC) -std=gnu99 -O1 -g -DYV_GC -include tools/bootstrap/gc.h -Itools/bootstrap -Isrc/c _check/bootstrap.c $(BOOT_RUNTIME) -l:libgc.so.1 -lm -o _check/cycc-generated-gc

bootstrap-update: c-bootstrap-gc
	$(call CAP,$(CYCC_MEM_KB)) _check/cycc-generated-gc --gc=never -o _check/seed-y1 src/y/ycc.y
	_check/seed-y1 --std-pack _check/seed-std.pack
	cat _check/seed-y1 _check/seed-std.pack > _check/seed-y1p
	chmod 755 _check/seed-y1p
	$(call CAP,$(YCC_MEM_KB)) _check/seed-y1p --gc=never -o _check/seed-y2 src/y/ycc.y
	cat _check/seed-y2 _check/seed-std.pack > _check/seed-y2p
	chmod 755 _check/seed-y2p
	$(call CAP,$(YCC_MEM_KB)) _check/seed-y2p --gc=never -o _check/seed-y3 src/y/ycc.y
	cmp _check/seed-y2 _check/seed-y3
	$(call CAP,$(YCC_MEM_KB)) ./ynew --gc=never -o _check/seed-independent src/y/ycc.y
	cmp _check/seed-y1 _check/seed-independent
	python3 tools/bootstrap/update.py _check/bootstrap.c
	cp _check/cycc-generated-gc cycc

c-bootstrap-test: ynew
	python3 tools/bootstrap/test.py

c-bootstrap-smoke: c-bootstrap
	python3 tools/bootstrap/test.py --bootstrap _check/cycc-generated

## ycc         the generated C seed builds Y; attach the pack and verify a self-compile
ycc: cycc $(YCC_SRCS) $(STD_SRCS) $(ARCH_SRCS) $(WEB_SRCS)
	$(call CAP,$(CYCC_MEM_KB)) ./cycc --gc=never -o _ycc0 src/y/ycc.y
	$(call PACKSTUB,_ycc0,ycc)
	$(call CAP,$(YCC_MEM_KB)) ./ycc --gc=never -o _ycc src/y/ycc.y
	cmp _ycc0 _ycc
	rm -f _ycc _ycc0
	@echo "verified: generated C seed output == Y self-compile (byte-identical)"

# A fresh checkout has no blessed reference: seed it from the verified ./ycc.
# `make rebless` replaces it later; once it exists it is never rebuilt here.
ifeq ($(wildcard refs/ycc.ref),)
refs/ycc.ref: ycc
	mkdir -p refs
	cp ycc refs/ycc.ref
	cd refs && sha256sum *.ref > SHA256SUMS
endif

## ynew        src/y built by BOOT, then twice by itself (generations 2 and 3
##             must be identical); needs no C port
ynew: $(YCC_SRCS) $(BOOT) $(STD_SRCS) $(ARCH_SRCS) $(WEB_SRCS) tools/bootstrap-stage.py
	python3 tools/bootstrap-stage.py $(BOOT) _ynew1
	$(call CAP,$(YCC_MEM_KB)) ./_ynew1 --gc=never -o _ynew2 src/y/ycc.y
	$(call PACKSTUB,_ynew2,_ynewp)
	$(call CAP,$(YCC_MEM_KB)) ./_ynewp --gc=never -o _ynew3 src/y/ycc.y
	cmp _ynew2 _ynew3
	mv _ynewp ynew
	rm -f _ynew1 _ynew2 _ynew3
	@echo "ynew built from src/y by $(BOOT): generations 2 and 3 are byte-identical"

## ycc-aarch64 build a self-contained AArch64 Linux compiler with both pack stubs
ycc-aarch64: ynew $(YCC_SRCS) $(STD_SRCS) $(ARCH_SRCS) $(WEB_SRCS)
	@d=$$(mktemp -d -t y-aarch64.XXXXXXXX) || exit $$?; trap 'rm -rf "$$d"' EXIT; \
	  ./ynew --target=linux --arch=aarch64 --gc=never -o "$$d/base" src/y/ycc.y </dev/null && \
	  $(call PACKSTUB,ynew,"$$d/packed","$$d/base") && \
	  cp "$$d/packed" $@

## yserve      the language server; cycc and current Y sources must agree
# Compare implementations of the same compiler revision. The blessed YREF may
# intentionally predate code-generation changes while they are being measured.
yserve: $(LSP_SRC) $(YCC_SRCS) $(STD_SRCS) $(ARCH_SRCS) $(WEB_SRCS) cycc ynew
	@rm -f yserve _yserve0 _yserve1 _yserve1p
	$(call CAP,$(CYCC_MEM_KB)) ./cycc --gc=auto -o _yserve0 src/tools/lsp/yserve.y
	$(call PACK,_yserve0,yserve)
	$(call CAP,$(CYCC_MEM_KB)) ./ynew --gc=auto -o _yserve1 src/tools/lsp/yserve.y
	$(call PACK,_yserve1,_yserve1p)
	@if cmp -s yserve _yserve1p; then \
	  echo "verified: cycc output == ./ynew output == yserve (byte-identical)"; \
	else \
	  echo "yserve: cycc and ./ynew DISAGREE. yserve imports the compiler's own"; \
	  echo "  modules, so a C/Y divergence shows up here first; run 'make port-check'."; \
	  rm -f _yserve0 _yserve1 _yserve1p; exit 1; \
	fi
	@rm -f _yserve0 _yserve1 _yserve1p

## ytest       the test runner and the development tools, written in Y
##             (src/tools/ytest; `./ytest help`); native Y builds it when available
YTEST_SRCS = $(wildcard src/tools/ytest/*.y)
# A source-only bootstrap still works without refs/: build with the C seed.
YTEST_BOOT ?= $(if $(wildcard $(BOOT)),./ynew,./cycc)
ytest: $(YTEST_BOOT) $(YTEST_SRCS) $(STD_SRCS) $(ARCH_SRCS)
	$(call CAP,$(CYCC_MEM_KB)) $(YTEST_BOOT) --gc=auto -o ytest src/tools/ytest/ytest.y </dev/null

## aarch64-test cross-compile the native fixtures and run them with qemu-aarch64
aarch64-test: cycc ynew ytest
	CYCC=$(CURDIR)/cycc YREF=$(CURDIR)/ynew YCC=$(CURDIR)/ynew ./ytest -j4 aarch64

## pack-bench  what --pack costs: the packed size of ./ycc method by method,
##             with the external compressors' floor and the startup overhead
pack-bench: ycc ytest
	./ytest pack-bench ./ycc

## cycc.exe    the generated C seed cross-built for Windows (no collector)
ifeq ($(OS),Windows_NT)
MINGW ?= $(GCC)
else
MINGW ?= x86_64-w64-mingw32-gcc
endif
cycc.exe: bootstrap/ycc.c $(BOOT_RUNTIME) $(BOOT_HEADERS)
	$(MINGW) -std=gnu99 -O1 -g -Wl,--stack,8388608 -Itools/bootstrap -Isrc/c bootstrap/ycc.c $(BOOT_RUNTIME) -lm -o cycc.exe

## pe-test     the Windows gates: PEs run on a real Windows machine named in the
##             git-ignored .pe-vm.conf (pe-vm.conf.example; ssh to a VM, or the
##             local backend on Windows). Never wine; not part of `make test`.
##             The compiler under test is $(NEW).
pe-test: ytest $(NEW_DEP)
	./ytest pe-gate $(NEW)
	./ytest pe-packinv $(NEW)
	./ytest pe-fixtures $(NEW)

## pe-cycc     cycc.exe run on that machine compiles what cycc compiles
pe-cycc: ytest cycc.exe
	./ytest cycc-win

## os          Y-OS image and filesystem in os/build/; run-os boots it
os/build/os.img os/build/os.fs: ycc ytest $(OS_SRCS) $(STD_SRCS)
	./ytest os-build ./ycc
os: os/build/os.img
run-os: os
	./ytest os-run

## run-os-gui  boot Y-OS with a screen (OS_VGA=virtio|std, OS_AUDIO=pipewire|pa|none);
##             F1 or F12 flips terminal and GUI
run-os-gui: os
	./ytest os-run --gui

## ── the development loop ─────────────────────────────────────────────────
## obf-audit   build a sealed sample and run the external scan/tamper/gdb checks
obf-audit: ycc
	@d=$$(mktemp -d -t y-obf-audit.XXXXXXXX) || exit $$?; trap 'rm -rf "$$d"' EXIT; \
	  printf 'def main() -> long { print("OBF_AUDIT_MARKER"); 0 };\nlet r = main();\n' > "$$d/p.y"; \
	  ./ycc --ob=full --ob-seed=7 --ob-map="$$d/map" "$$d/p.y" -o "$$d/p" && \
	  python3 tools/obf-audit/audit.py scan "$$d/p" --marker OBF_AUDIT_MARKER --map "$$d/map" && \
	  python3 tools/obf-audit/audit.py tamper "$$d/p" && \
	  python3 tools/obf-audit/audit.py gdb "$$d/p"

## check       C seed builds NEW byte for byte, fast suites pass, then NEW
##             is compared with BASE (programs, instruction counts, timings)
check: cycc ytest $(BASE) $(NEW_DEP) lsp-grammar-check
	./ytest check $(BASE) $(NEW) $(or $(ROUNDS),3)

## rebless     native development bless: three generations, native/ycc fixtures;
##             60 s total budget (REBLESS_TIMEOUT). No C corpus sweep.
## rebless-full exhaustive C-seed self-compile + Linux/PE port gates;
##             independently compare C/Y std packs, 120 s budget (REBLESS_FULL_TIMEOUT)
rebless:
	timeout -k 5s $(REBLESS_TIMEOUT)s $(MAKE) --no-print-directory _rebless </dev/null

_rebless: ynew ytest
	YREF=$(CURDIR)/ynew YCC=$(CURDIR)/ynew CYCC=$(CURDIR)/ynew YQUIET=1 YPORT_SELF=0 ./ytest -j $(JOBS) native ycc </dev/null
	cp ynew refs/ycc.ref
	cd refs && sha256sum *.ref > SHA256SUMS
	cp ynew ycc
	@echo "blessed refs/ycc.ref $$(sha256sum refs/ycc.ref | cut -c1-16) (native; C audit: make rebless-full)"

rebless-full:
	timeout -k 5s $(REBLESS_FULL_TIMEOUT)s $(MAKE) --no-print-directory _rebless-full </dev/null

_rebless-full: cycc ytest
	@d=$$(mktemp -d -t y-rebless.XXXXXXXX) || exit $$?; trap 'rm -rf "$$d"' EXIT; \
	  echo "rebless-full: compile std once with C, then verify self-compilation and C/Y pack equality" && \
	  ./cycc --std-pack "$$d/c.pack" </dev/null && \
	  cat cycc "$$d/c.pack" > "$$d/cycc" && chmod 755 "$$d/cycc" && \
	  "$$d/cycc" --gc=never -o "$$d/seed" src/y/ycc.y </dev/null && \
	  cat "$$d/seed" "$$d/c.pack" > "$$d/seedp" && chmod 755 "$$d/seedp" && \
	  ( $(call CAP,$(YCC_MEM_KB)) "$$d/seedp" --gc=never -o "$$d/self" src/y/ycc.y </dev/null ) && \
	  cmp "$$d/seed" "$$d/self" && \
	  "$$d/seed" --target=linux --gc=never -o "$$d/xstub" src/y/packstub.y </dev/null && \
	  "$$d/seed" --target=linux --arch=aarch64 --gc=never -o "$$d/astub" src/y/packstub.y </dev/null && \
	  printf 'YCCSTB2!%08d' "$$(stat -c%s "$$d/xstub")" > "$$d/stub" && \
	  cat "$$d/xstub" "$$d/astub" >> "$$d/stub" && \
	  "$$d/seed" --std-pack "$$d/std.pack" </dev/null && \
	  cmp "$$d/c.pack" "$$d/std.pack" && \
	  printf '%08dYCCSTUB1' "$$(stat -c%s "$$d/stub")" > "$$d/frame" && \
	  cat "$$d/seed" "$$d/stub" "$$d/frame" "$$d/std.pack" > "$$d/packed" && chmod 755 "$$d/packed" && \
	  CYCC="$$d/cycc" YREF="$$d/packed" YQUIET=1 YPORT_SELF=0 ./ytest -j $(JOBS) port pe-port </dev/null && \
	  cp "$$d/packed" refs/ycc.ref && \
	  (cd refs && sha256sum *.ref > SHA256SUMS) && \
	  cp "$$d/packed" ycc && \
	  echo "blessed refs/ycc.ref $$(sha256sum refs/ycc.ref | cut -c1-16) (full C audit)"

## port-check  the C seed against ./ynew (lists only programs that differ)
port-check: cycc ytest ynew
	YREF=$(CURDIR)/ynew YQUIET=1 ./ytest -j $(JOBS) port

## corpus-diff programs in test/y and src/y/ycc.y (or FILES="a.y b.y") that
##             BASE and NEW compile differently
corpus-diff: ytest $(BASE) $(NEW_DEP)
	./ytest corpus-diff $(BASE) $(NEW) $(FILES)

## bench       timings of BASE against NEW (ROUNDS pairs, default 5)
## bench-ir    exact instruction counts of the compiles
bench: ytest $(BASE) $(NEW_DEP)
	./ytest bench $(BASE) $(NEW) $(or $(ROUNDS),5)
bench-ir: ytest $(BASE) $(NEW_DEP)
	./ytest bench-ir $(BASE) $(NEW)

## web-browser the browser tests in headless Chromium and Firefox (by hand,
##             like pe-test: a browser cannot run under the address-space cap)
web-browser: ycc ytest
	@# The browser runs under a MemoryMax cgroup, not RLIMIT_AS:
	@# Chromium reserves far more address space than it uses.  Lift the soft
	@# virtual cap for this by-hand target only; the driver's timeouts bound it.
	@/bin/bash -c 'ulimit -S -v unlimited 2>/dev/null || true; exec ./ytest -j1 web-browser'

## ── tests (./ytest; SUITES="port native" narrows, ./ytest list names them) ─
## test        the fast suites, with the built ./ycc
## test-slow   the slow ones (port sweeps, self-compile, kernel, Y-OS, lsp, gc stress, pack, pkg)
## test-all    both
## test-fast   the fast suites with only ./cycc (the suites that need ./ycc skip)
test: ycc ytest refs/ycc.ref
	YPORT_SELF=0 ./ytest -j $(JOBS) $(SUITES)
test-slow: ycc ytest refs/ycc.ref
	YPORT_SELF=0 ./ytest -j $(JOBS) slow
test-all: ycc ytest refs/ycc.ref
	YPORT_SELF=0 ./ytest -j $(JOBS) all
test-fast: cycc ytest
	./ytest -j $(JOBS) $(SUITES)

## test-compile  compile and run one example with both compilers
test-compile: cycc ycc
	@d=$$(mktemp -d -t ycc-hello.XXXXXX) && \
	  ./cycc --gc=auto -o $$d/c test/y/examples/helloworld.y && $$d/c && \
	  ./ycc --gc=auto -o $$d/y test/y/examples/helloworld.y && $$d/y; rc=$$?; rm -rf $$d; exit $$rc

## asan / test-asan   sanitized cycc (every finding fatal) and the suites on it
ASAN_FLAGS = -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g
cycc-asan: bootstrap/ycc.c $(BOOT_RUNTIME) $(BOOT_HEADERS)
	$(GCC) -std=gnu99 -O1 -Itools/bootstrap -Isrc/c $(ASAN_FLAGS) bootstrap/ycc.c $(BOOT_RUNTIME) -lm -o cycc-asan
asan: cycc-asan
test-asan: cycc-asan ytest
	ulimit -s 65536; CYCC=$(CURDIR)/cycc-asan YCC=$(CURDIR)/cycc-asan ASAN_OPTIONS=detect_leaks=0:hard_rss_limit_mb=$(ASAN_RSS_MB) \
	    ./ytest $(SUITES_ASAN)

## valgrind    memcheck errors in the generated C seed
valgrind: cycc
	@d=$$(mktemp -d -t cycc-vg.XXXXXX) && \
	  valgrind --error-exitcode=1 --quiet ./cycc --gc=auto -o $$d/out test/y/examples/helloworld.y; rc=$$?; rm -rf $$d; exit $$rc

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
## lsp-grammar / lsp-grammar-check  refresh or verify the editor vocabulary
lsp-grammar lsp-grammar-check: cycc src/y/language_schema.y src/tools/lsp/vscode-y-lang/grammar.y
	@task_scratch=$$(mktemp -d -t y-grammar.XXXXXXXX) || exit $$?; trap 'rm -rf "$$task_scratch"' EXIT; \
	  $(call CAP,$(CYCC_MEM_KB)) ./cycc --gc=auto -o "$$task_scratch/grammar" src/tools/lsp/vscode-y-lang/grammar.y </dev/null || exit $$?; \
	  $(call CAP,$(YCC_MEM_KB)) "$$task_scratch/grammar" src/tools/lsp/vscode-y-lang/syntaxes/y.tmLanguage.json $(if $(filter lsp-grammar-check,$@),--check,) </dev/null
.PHONY: lsp-grammar lsp-grammar-check

lsp-ext: lsp-grammar
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
# `tectonic` may live in ~/.local/bin without being on PATH (a per-user
# install); prefer PATH, then that location.
TECTONIC ?= $(shell command -v tectonic 2>/dev/null || { [ -x "$$HOME/.local/bin/tectonic" ] && printf '%s\n' "$$HOME/.local/bin/tectonic"; })
docs: $(DOC_PDF)
$(DOC_PDF): $(wildcard docs/src/*.tex) docs/Tectonic.toml
	@command -v "$(TECTONIC)" >/dev/null 2>&1 || test -x "$(TECTONIC)" \
	  || { echo "make docs: no tectonic, skipped"; exit 0; }
	@mkdir -p $(DOC_OUT)
	cd docs/src && (cat _preamble.tex index.tex _postamble.tex \
	    | "$(TECTONIC)" --outdir $(CURDIR)/$(DOC_OUT) --keep-logs -) \
	  || { echo "make docs: tectonic failed; its diagnostics are above"; exit 1; }
	@mv $(DOC_OUT)/texput.pdf $(DOC_PDF)
	@mv $(DOC_OUT)/texput.log $(DOC_LOG)
	@! grep -q '^! ' $(DOC_LOG) || { echo "make docs: LaTeX errors, see $(DOC_LOG)"; exit 1; }
	@! grep -qE '^(Overfull|Underfull) \\hbox' $(DOC_LOG) || { echo "make docs: over/underfull \\hbox, see $(DOC_LOG)"; exit 1; }
	@echo "manual: $(DOC_PDF) ($$(stat -c%s $(DOC_PDF)) bytes), no errors and no warnings"

clean:
	rm -f src/c/*.o ycc-aarch64 cycc cycc.exe cycc-asan ycc ynew ytest yserve a.out
	rm -f _yserve0 _yserve1 _yserve1p yserve.pack
	rm -f _ycc _ycc0 _ycc0.pack _ycc0.stub _ycc0.stub.len ycc.pack ycc.stub ycc.stub.len _ynew1 _ynew2 _ynew3 _ynewp _ynewp.pack _ynewp.stub _ynewp.stub.len _rb1 _rb2 _rbp _rbp.pack _rbp.stub _rbp.stub.len
	rm -rf _check docs/build os/build

.PHONY: all help clean ycc yserve pack-bench aarch64-test pe-test pe-cycc os run-os run-os-gui \
        obf-audit check rebless rebless-full _rebless _rebless-full port-check corpus-diff bench bench-ir \
        web-browser test test-slow test-all test-fast test-compile asan test-asan valgrind asm-check \
        fmt fmt-check lsp-ext lsp-vsix lsp-e2e docs \
        c-bootstrap c-bootstrap-test c-bootstrap-smoke c-bootstrap-gc bootstrap-update
