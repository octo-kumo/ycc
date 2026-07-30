#!/bin/bash
# Build the Y compiler as a single self-contained WASM file for the browser.
# Output: wasm/ycc-single.js  (~204KB, ~72KB gzipped) — wasm embedded as base64.
#
# This compiles the C compiler's VM mode to WebAssembly. User .y programs are
# interpreted by the VM inside the browser; multi-file imports resolve through
# Emscripten's in-memory filesystem (MEMFS).
set -e
cd "$(dirname "$0")/.."

emcc -O2 -s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME=createYcc \
  -s SINGLE_FILE=1 \
  -s ALLOW_MEMORY_GROWTH=1 -s ENVIRONMENT=web,node \
  -s EXPORTED_RUNTIME_METHODS='["FS","callMain"]' \
  -s INVOKE_RUN=0 \
  main.c parser.c codegen.c vm.c ast.c typecheck.c module.c map.c lib.c \
  runtime.c type.c ast_debug.c parser_debug.c \
  -o wasm/ycc-single.js

echo "built wasm/ycc-single.js ($(stat -c%s wasm/ycc-single.js) bytes, $(gzip -c wasm/ycc-single.js | wc -c) gzipped)"
