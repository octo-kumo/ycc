GCC=gcc
# The C compiler is a 1:1 copy of the Y compiler (see PORTING.md): it compiles .y straight to a native ELF exactly like ycc.
# -O1 is about the TEST LOOP, not the shipped artifact (that is `ycc`, which
# cycc only has to agree with byte for byte). Every suite compiles its whole
# corpus with cycc as well as with the Y compiler, and `make rebless` is
# mostly that: measured at 13.0 s with -O0, the port suite is nearly all of it,
# and cycc is the slow half -- ~11x the Y compiler's per-compile time
# (20.5 ms against 1.8 ms on test/y/native/t100_tail_call_space.y).
#
# Two things made cycc slow, and neither was the value model:
#   - it was built with no -O flag at all, so -O0;
#   - 65% of its instructions were record lookups (callgrind), whose biggest
#     single piece was a LIBC strcmp PER FIELD ACCESS -- 36% on its own --
#     because the C copy reaches every record field through yr_get while the
#     Y compiler's own field reads are native offset loads. That compare is
#     inlined in yv.c now.
# Together: 206.7M -> 126.3M instructions compiling that fixture (-39%), 100
# compiles 2.05 s -> 1.33 s, the port suite 16 s (-j 4) -> 7.7 s (-j 8), and
# rebless 13.0 s -> 9.4 s, and 18.5 s MEASURED now that it runs the WINDOWS half
# of the port gate too (pe-port is 8.1 s of that, sharded). At -O0 the inline
# compare alone buys NOTHING
# (2.07 s): the loop needs the optimizer, so the flag and the inline are one
# change. -O2 measured no better on the suite (7.9 s) for a 9.4 s build
# instead of 5.7 s, so -O1. What says none of this changed what cycc EMITS is
# the port gate: 553 fixtures, twice (default and -W 1), byte-identical.
CFLAGS=-Wall -Wextra -std=gnu99 -O1 -g
CYC_SRCS=$(wildcard src/c/*.c)
CY_HDRS=$(wildcard src/c/*.h)
CYCC=cycc

# Every recipe line runs under an address-space cap below 4 GB (this machine
# goes down past 4 GB): test/sh/capped.sh sets it and runs /bin/sh.
SHELL := $(CURDIR)/test/sh/capped.sh

# The Y compiler sources: what the compiler compiles (and mirrors in C).
YCC_SRCS=src/y/ycc.y src/y/tags.y src/y/target.y src/y/pkg.y src/y/lexer.y src/y/parser.y src/y/types.y src/y/native.y src/y/labels.y src/y/ir.y src/y/arch_x64.y src/y/rename.y src/y/enc64.y src/y/asm.y src/y/elf.y src/y/pe.y src/y/dwarf.y src/y/lint.y src/y/meta.y src/y/std/fs.y src/y/std/net.y src/y/std/struct.y src/y/std/prelude.y src/y/std/exec.y src/y/std/rt.y src/y/std/str.y

# The std files the compiler splices into programs, embedded into it when
# it is built: native.y says `embed RT_SRC from "./std/rt.y";`, the C copy
# Y_EMBED(...) — an .incbin, so the C build reads them too (from the repo
# root, where these rules run gcc).
STD_EMBEDS=src/y/std/rt.y src/y/std/prelude.y src/y/std/exec.y src/y/std/str.y

# The assembly the compiler hands to asm.y for every program, in src/y/arch/,
# embedded the same way: arch_x64.y says `embed PRELUDE_ASM from
# "./arch/prelude.s";`, the C copy Y_EMBED(PRELUDE_ASM, "src/y/arch/prelude.s").
# One copy of the asm, read by both compilers (`make asm-check`).
ARCH_EMBEDS=$(wildcard src/y/arch/*.s)

all: cycc

# [1/3] gcc builds the C copy of the compiler.
cycc: $(CYC_SRCS) $(CY_HDRS) $(STD_EMBEDS) $(ARCH_EMBEDS)
	$(GCC) $(CFLAGS) -o cycc $(CYC_SRCS)
	@echo "cycc built: the C copy of the compiler ($$(stat -c%s cycc) bytes)"

# GNU as reads the arch assembly: a second opinion on every line of it, so a
# typo in hand-written asm is caught here and not by the first program that
# calls the routine. ycc's own assembler stays the authority — these files are
# FRAGMENTS spliced into a program, so two things differ from a whole .s and
# are normalised before as sees them:
#   - `$ystr_x_end-ystr_x`, a length immediate whose two labels live in
#     arch_consts (still Y), which as cannot resolve inside a fragment;
#   - operand size: `mov $0, (%rax)` is a movq here, a warning there.
# Undefined labels are NOT this target's business: a wrong one is an
# `undefined label` from asm_link, which every suite hits immediately.
asm-check:
	@command -v as >/dev/null 2>&1 || { echo "asm-check: no GNU as, skipped"; exit 0; }
	@rc=0; for f in $(ARCH_EMBEDS); do \
	    sed -E 's/\$$[A-Za-z_0-9]+-[A-Za-z_0-9]+/$$0/g' $$f > /tmp/asm-check.s; \
	    if as -o /dev/null /tmp/asm-check.s 2>/tmp/asm-check.err; then \
	        echo "  ok   $$f"; \
	    else echo "  FAIL $$f"; sed 's/^/    /' /tmp/asm-check.err; rc=1; fi; \
	  done; rm -f /tmp/asm-check.s /tmp/asm-check.err; \
	  if [ $$rc = 0 ]; then echo "asm-check: GNU as reads every arch .s file"; fi; exit $$rc

# [2/3] the C copy compiles the compiler -> ycc (native static ELF, no
# toolchain), which then compiles the std units and carries them: PACK
# appends `BIN --std-pack` to BIN (src/y/ycc.y self_pack reads it back), so
# a compile links the runtime instead of compiling it. [3/3] acceptance:
# ycc must be byte-identical to the backed-up reference binary — that is the
# C copy validated against the real ycc, its pack included — and its own
# self-compile (with that pack) must rebuild it (fixpoint).
# Every process a target starts runs under a memory cap below 4 GB (this
# machine goes down past that): ulimit -v (in KB) on the compilers, and on
# ASan builds, which reserve terabytes of address space, ASan's own RSS
# limit. A memory regression then fails the build ("out of memory") instead
# of taking the machine: cycc needs ~1.9 GB for ycc.y, ycc itself ~1.1 GB.
MEM_KB=3670016
CYCC_MEM_KB=$(MEM_KB)
YCC_MEM_KB=2097152
ASAN_RSS_MB=3500
# $(call PACK,BIN,OUT): OUT = BIN with its std pack attached.
PACK = ./$(1) --std-pack $(2).pack && cat $(1) $(2).pack > $(2) && chmod 755 $(2) && rm -f $(2).pack
ycc: cycc $(YCC_SRCS) $(CYC_SRCS) $(CY_HDRS) $(STD_EMBEDS) $(ARCH_EMBEDS)
	ulimit -v $(CYCC_MEM_KB); ./cycc -o _ycc0 src/y/ycc.y
	$(call PACK,_ycc0,ycc)
	cmp ycc refs/ycc.ref
	ulimit -v $(YCC_MEM_KB); ./ycc -o _ycc src/y/ycc.y
	cmp _ycc0 _ycc
	rm -f _ycc _ycc0
	@echo "verified: cycc output == refs/ycc.ref == ycc self-compile (byte-identical)"

# The test/metrics runner (src/tools/ytest/README.md). Like the language
# server it is an ordinary Y program built by the compiler, and it is NOT in
# `make test`: a coverage run rebuilds the compiler with --coverage and is a
# measurement, not a gate.
ytest: ycc
	./ycc src/tools/ytest/ytest.y -o ytest
	@echo "ytest built: ./ytest suites|coverage|report"

# [W1] the Windows build of the C copy, cross-compiled with mingw-w64. It is
# the SAME source as cycc -- src/c/ylong.h is what makes Y's 64-bit long hold
# on LLP64 -- so this is a second host for one compiler, not a second compiler.
# The gate is test/sh/cycc-win.sh: every fixture cycc.exe compiles under wine
# must be byte-identical to Linux cycc's. `-S` too (binary-mode stdout). `-g`
# embeds the host's own absolute cwd, which is a different string on Windows
# by construction, so it is compared host-against-host, not across hosts.
MINGW ?= x86_64-w64-mingw32-gcc
cycc.exe: $(CYC_SRCS) $(CY_HDRS) $(STD_EMBEDS) $(ARCH_EMBEDS)
	$(MINGW) $(CFLAGS) -o cycc.exe $(CYC_SRCS)
	@echo "cycc.exe built: the C copy for Windows ($$(stat -c%s cycc.exe) bytes)"

# AddressSanitizer + UBSan build of the C copy (one command, no CI). Every
# finding is fatal (-fno-sanitize-recover): UBSan's default is to print and
# carry on, and a suite that compares outputs never sees a report it printed.
ASAN_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g

cycc-asan: $(CYC_SRCS) $(CY_HDRS) $(STD_EMBEDS) $(ARCH_EMBEDS)
	$(GCC) $(CFLAGS) $(ASAN_FLAGS) -o cycc-asan $(CYC_SRCS)

asan: cycc-asan

# The suites read the compiler they test from the environment: $CYCC (lib.sh,
# ytool.sh — the C copy) and $YCC (the suites that drive a built ./ycc). Both
# must name cycc-asan, or the sanitized build is never exercised at all.
# $YREF stays refs/ycc.ref: the golden reference is deliberately unsanitized,
# and it is what the sanitized build's bytes are compared against.
# Suites that need ./ycc (ycc, fixpoint, native, native-examples, debug, link)
# skip themselves unless it is built; SUITES_ASAN is normally a subset, since a
# sanitized self-compile wants orders of magnitude more memory than a plain one.
test-asan: cycc-asan
	CYCC=$(CURDIR)/cycc-asan YCC=$(CURDIR)/cycc-asan ASAN_OPTIONS=detect_leaks=0:hard_rss_limit_mb=$(ASAN_RSS_MB) \
	    ./test/sh/run_all.sh $(SUITES_ASAN)

# Full suite (see test/sh/). Suites compare the C copy's output against
# the reference ycc and run the compiled programs, JOBS at a time (the long
# ones in shards); each one's output is printed whole once all are done,
# JOBS=1 runs them one by one with live output. Building ./ycc was the port
# gate on src/y/ycc.y itself, so the port suite leaves it out (YPORT_SELF=0).
JOBS ?= $(shell nproc)
test: ycc
	YPORT_SELF=0 ./test/sh/run_all.sh -j $(JOBS) $(SUITES)

# Same suites without the acceptance gate: only ./cycc is built, so the six
# suites that drive a built ./ycc (ycc, fixpoint, native, native-examples,
# debug, link) announce themselves as skipped. Use for a quick signal; `make
# test` is the real one.
test-fast: cycc
	./test/sh/run_all.sh -j $(JOBS) $(SUITES)

# Tiny smoke test: compile + run one example with both compilers.
test-compile: cycc ycc
	./cycc -o /tmp/hello_c test/y/examples/helloworld.y && /tmp/hello_c
	./ycc -o /tmp/hello_y test/y/examples/helloworld.y && /tmp/hello_y

# The language server (src/tools/lsp/, designed in src/tools/lsp/LSP.md). It is
# a Y program like any other, so it builds with the compiler -- and it wants the
# std pack, because a server that spent every request recompiling the std units
# would be unusable. $(call PACK) attaches it exactly as for ./ycc.
#
# The two compilers must produce identical bytes. yserve imports the compiler's
# own modules by path, so this is a real port check on top of a build: anything
# that differed between the copies would show up here and nowhere else, since no
# other program in the tree imports types.y, native.y and friends.
#
# $(YREF), not ./ycc: `make ycc` is the acceptance gate on the compiler itself
# and rebuilds it, so depending on it would make building the server wait on --
# and fail with -- whatever the compiler's own state happens to be.
LSP_SRC := $(wildcard src/tools/lsp/*.y)
# The reference compiler, as the suites call it: the last blessed build.
YREF ?= $(CURDIR)/refs/ycc.ref
yserve: $(LSP_SRC) src/y/std/json.y cycc
	@rm -f yserve _yserve0 _yserve1 _yserve1p
	ulimit -v $(CYCC_MEM_KB); ./cycc -o _yserve0 src/tools/lsp/yserve.y
	$(call PACK,_yserve0,yserve)
	ulimit -v $(CYCC_MEM_KB); $(YREF) -o _yserve1 src/tools/lsp/yserve.y
	$(call PACK,_yserve1,_yserve1p)
	@if cmp -s yserve _yserve1p; then \
	  echo "verified: cycc output == $(YREF) output == yserve (byte-identical)"; \
	else \
	  echo "yserve: the two compilers DISAGREE (cycc vs $(YREF))"; \
	  echo "  yserve is the only program that imports the compiler's own modules by"; \
	  echo "  path -- types.y, native.y, parser.y, rename.y, lint.y -- so a C/Y"; \
	  echo "  divergence shows up here first. It is the same failure as the"; \
	  echo "  'cmp ycc refs/ycc.ref' in make ycc and the one test_port.sh reports,"; \
	  echo "  NOT a bug in the server. Run 'make port-check' first."; \
	  rm -f _yserve0 _yserve1 _yserve1p; exit 1; \
	fi
	rm -f _yserve0 _yserve1 _yserve1p

# The extension's TypeScript. Separate from yserve because it needs node and npm,
# which the compiler itself must never depend on. `npm ci` when a lockfile is
# present so the build is reproducible, `npm install` otherwise.
lsp-ext:
	cd src/tools/lsp/vscode-y-lang && \
	  { [ -f package-lock.json ] && npm ci || npm install; } && npm run compile

# The installable .vsix. Depends on lsp-ext, and NOT on yserve: the extension
# finds the server at runtime, so shipping one inside the package would bake in
# the machine it was built on.
lsp-vsix: lsp-ext
	cd src/tools/lsp/vscode-y-lang && \
	  npx -y @vscode/vsce package --no-git-tag-version --allow-missing-repository

# The server driven as a process: framing, fork containment, state across
# messages, and the extension's activation. Kept out of `make test` -- it needs a
# process per case, so it is slow; test/sh/test_lsp.sh runs the fixtures and the
# formatter instead. The two Node checks skip themselves when the extension's
# node_modules are absent.
lsp-e2e: yserve
	sh src/tools/lsp/test/test-e2e.sh

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
# second and third must be byte-identical (the fixpoint); the third is
# compiled with the second's std pack attached, so that is checked too.
# Needs no C port.
ynew: $(YCC_SRCS) $(BOOT) $(STD_EMBEDS) $(ARCH_EMBEDS)
	ulimit -v $(YCC_MEM_KB); $(abspath $(BOOT)) -o _ynew1 src/y/ycc.y
	ulimit -v $(YCC_MEM_KB); ./_ynew1 -o _ynew2 src/y/ycc.y
	$(call PACK,_ynew2,_ynewp)
	ulimit -v $(YCC_MEM_KB); ./_ynewp -o _ynew3 src/y/ycc.y
	cmp _ynew2 _ynew3
	mv _ynewp ynew
	rm -f _ynew1 _ynew2 _ynew3
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
# program; on ycc.y it is that build) with its std pack attached; it
# becomes ./ycc too. Run `make check` first: it runs every suite on this
# same build.
# What the bless actually costs, measured on this machine (8 cores) — the
# question "why does rebless take so long" is answered by these five numbers,
# and the answer is that it does not: the two self-compiles are 1.4 s
# together, the pack and the cmp are hundredths, and the port suite over 141
# fixtures is 8.4 s of the 9.7 s total.
#
#   cycc -o _rb1 src/y/ycc.y     0.98 s   (the C copy compiles the compiler)
#   _rb1 -o _rb2 src/y/ycc.y     0.44 s   (the Y self-compile)
#   cmp _rb1 _rb2                0.00 s
#   the pack                     0.01 s
#   the port suite, -j 8         8.36 s   (142 fixtures, each compiled twice)
#   ----------------------------- 9.48 s
#
# The slowness people are remembering is elsewhere: `make cycc` from a clean
# tree is 5.5 s (and `make -j8 cycc` is the same 5.5 s -- src/c/native.c is one
# 12,000-line translation unit and it IS the build, so there is nothing for
# the job server to overlap), the full 20-suite run is 37 s, and `make check`
# adds the compare and bench phases on top of that. Those are the numbers to
# look at before touching this target: the port suite is 87% of it, and it is
# 87% of it because it compiles every fixture with both compilers, which is
# the whole point of the gate.
rebless: cycc
	ulimit -v $(CYCC_MEM_KB); ./cycc -o _rb1 src/y/ycc.y
	ulimit -v $(YCC_MEM_KB); ./_rb1 -o _rb2 src/y/ycc.y
	cmp _rb1 _rb2
	$(call PACK,_rb1,_rbp)
# BOTH HALVES OF THE PORT GATE, not just the Linux one. rebless is the step
# that ACCEPTS a compiler, and the PE walkers are invisible to the Linux port
# suite: round 52's bug (cycc --target=windows -g trapped on EVERY program, for
# ten rounds, with every suite green) lived in a PE walker and would have been
# blessed by this very line. pe-port is sharded 8 ways under -j like port is, so
# it adds a shard rather than a suite.
	YREF=$(CURDIR)/_rbp YQUIET=1 YPORT_SELF=0 ./test/sh/run_all.sh -j $(JOBS) port pe-port
	cp _rbp refs/ycc.ref
	cd refs && sha256sum *.ref > SHA256SUMS
	mv _rbp ycc
	rm -f _rb1 _rb2
	@echo "blessed refs/ycc.ref $$(sha256sum refs/ycc.ref | cut -c1-16)"

clean:
	rm -f $(CYC_SRCS:src/c/%.c=src/c/%.o) cycc cycc.exe cycc-asan ycc _ycc _ycc0 _ycc0.pack ycc.pack a.out
	rm -f ynew _ynew1 _ynew2 _ynew3 _ynewp _ynewp.pack _rb1 _rb2 _rbp _rbp.pack ytest ytest-report.md
	rm -rf _check docs/build

# Memcheck the C copy on a real input. NOTE: no --leak-check=full: the Y
# value model (src/c/yv.c) never frees, so a leak gate could never be clean
# and the target would fail for the wrong reason. We gate on memcheck
# ERRORS (invalid reads/writes, uninitialised values), which is what can
# actually regress.
valgrind: cycc
	valgrind --error-exitcode=1 --quiet ./cycc -o /tmp/cycc-vg test/y/examples/helloworld.y

# ── The reference manual (docs/src/), typeset with tectonic ────────────────
# `make docs` -> docs/build/manual.pdf.
#
# Tectonic takes exactly ONE input, and docs/Tectonic.toml names three:
# _preamble, index, _postamble. Those three entries say what the document is --
# one file, in that order, with index.tex \input-ing the ten chapters -- so the
# recipe does the concatenation itself and pipes the result in on stdin, which
# is `tectonic -`. That is why there is no _all.tex driver in docs/src: this
# recipe is the driver, and the document's structure stays in the config where
# it belongs. Run from docs/src so the chapters' \input paths resolve.
#
# The recipe FAILS on an error and on a warning, both counted out of the log
# tectonic keeps. A warning here is a line running into the margin or one
# stretched to nothing; the manual last typeset with none, and a target that
# only printed them is how 205 sat unnoticed for a while. The warning count is
# DISTINCT: tectonic runs XeTeX three times, so the same one appears in the log
# once but three times on stderr, and the log is what is read here.
#
# Not part of `make test`: it needs tectonic and, on a first run, the bundle in
# docs/Tectonic.toml fetched over the network. Nothing else in the build does,
# and the compiler must never depend on a TeX distribution.
DOC_OUT = docs/build
DOC_PDF = $(DOC_OUT)/manual.pdf
DOC_LOG = $(DOC_OUT)/manual.log
DOC_SRC = $(wildcard docs/src/*.tex)

docs: $(DOC_PDF)

$(DOC_PDF): $(DOC_SRC) docs/Tectonic.toml
	@command -v tectonic >/dev/null 2>&1 || { echo "make docs: no tectonic, skipped"; exit 0; }
	@mkdir -p $(DOC_OUT)
	cd docs/src && (cat _preamble.tex index.tex _postamble.tex \
	    | tectonic --outdir $(CURDIR)/$(DOC_OUT) --keep-logs -) \
	  || { echo "make docs: tectonic failed; its own diagnostics are above"; exit 1; }
	@mv $(DOC_OUT)/texput.pdf $(DOC_PDF)
	@mv $(DOC_OUT)/texput.log $(DOC_LOG)
	@if grep -q '^! ' $(DOC_LOG); then \
	    echo "make docs: $$(grep -c '^! ' $(DOC_LOG)) LaTeX error(s), see $(DOC_LOG)"; \
	    exit 1; \
	fi
	@if grep -qE '^(Overfull|Underfull) \\hbox' $(DOC_LOG); then \
	    echo "make docs: $$(grep -cE '^(Overfull|Underfull) \\hbox' $(DOC_LOG)) over/underfull \\hbox, see $(DOC_LOG)"; \
	    exit 1; \
	fi
	@echo "manual: $(DOC_PDF) ($$(stat -c%s $(DOC_PDF)) bytes, $$(grep -o '([0-9]* pages' $(DOC_LOG) | tail -1 | tr -d '()' | cut -d' ' -f1) pages), no errors and no warnings"

.PHONY: all clean valgrind test test-fast test-compile asan test-asan asm-check ycc yserve lsp-ext lsp-vsix lsp-e2e check port-check corpus-diff bench bench-ir rebless docs
