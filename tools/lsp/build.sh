#!/bin/bash
# Build the Y LSP checker as a browser wasm module.
# Pipeline: check_main.y --(./yboot -S)--> C --(emcc)--> single-file JS+wasm.
# (ycc itself is native-only now and no longer emits C; the reference C
# compiler provides the C-emission step.)
# Output: tools/lsp/check.js  (~200KB, wasm embedded as base64).
set -e
cd "$(dirname "$0")/../.."

echo "[1/2] compiler -S: check_main.y -> C"
./yboot -S tools/lsp/check_main.y -o /tmp/check_main.c

echo "[2/2] emcc: C -> wasm (single file)"
emcc -O2 -s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME=createCheck \
  -s SINGLE_FILE=1 \
  -s ALLOW_MEMORY_GROWTH=1 -s ENVIRONMENT=web,node \
  -s EXPORTED_RUNTIME_METHODS='["FS","callMain"]' \
  -s INVOKE_RUN=0 \
  -Isrc/c \
  /tmp/check_main.c src/c/runtime.c src/c/map.c src/c/lib.c src/c/type.c \
  -o tools/lsp/check.js

echo "built tools/lsp/check.js ($(stat -c%s tools/lsp/check.js) bytes, $(gzip -c tools/lsp/check.js | wc -c) gzipped)"
