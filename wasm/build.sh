#!/bin/bash
# Build the Y compiler as a single self-contained WASM file for the browser.
# Output: wasm/ycc-single.js  (~204KB, ~72KB gzipped) — wasm embedded as base64.
#
# This compiles the C copy of the compiler (src/c — the 1:1 twin of src/y,
# see PORTING.md). It compiles .y straight to native x86-64 ELFs, so the
# browser build produces BINARIES to download, not interpreted programs: the
# old VM-interpreter pipeline this script used to build (src/c/{main,vm,
# codegen,ast,typecheck,module,map,lib,runtime,type,ast_debug,parser_debug}.c)
# was deleted in the rewrite, and none of those files exist any more.
#
# UNVERIFIED: emcc is not installed on this machine, so this command has not
# been run since the rewrite. The source list below is the current one; expect
# to iterate on the emcc flags (the compiler leans on stdio + a few POSIX file
# calls in src/c/yv.c, and on ALLOW_MEMORY_GROWTH for large inputs).
set -e
cd "$(dirname "$0")/.."

emcc -O2 -s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME=createYcc \
  -s SINGLE_FILE=1 \
  -s ALLOW_MEMORY_GROWTH=1 -s ENVIRONMENT=web,node \
  -s EXPORTED_RUNTIME_METHODS='["FS","callMain"]' \
  -s INVOKE_RUN=0 \
  src/c/ycc.c src/c/yv.c src/c/lexer.c src/c/parser.c src/c/rename.c \
  src/c/types.c src/c/native.c src/c/arch_x64.c src/c/enc64.c \
  src/c/asm.c src/c/elf.c src/c/std_lines.c src/c/prof_lines.c \
  -o wasm/ycc-single.js

echo "built wasm/ycc-single.js ($(stat -c%s wasm/ycc-single.js) bytes, $(gzip -c wasm/ycc-single.js | wc -c) gzipped)"
