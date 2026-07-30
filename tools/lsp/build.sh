#!/bin/bash
# Build the Y LSP checker as a browser wasm module.
# Pipeline: check_main.y --(ycc1)--> C --(emcc)--> single-file JS+wasm.
# Output: tools/lsp/check.js  (~200KB, wasm embedded as base64).
set -e
cd "$(dirname "$0")/../.."

echo "[1/2] ycc1: check_main.y -> C"
YCC_RUNTIME_DIR="$(pwd)" /tmp/ycc1 -S tools/lsp/check_main.y -o /tmp/check_main.c

echo "[2/2] emcc: C -> wasm (single file)"
emcc -O2 -s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME=createCheck \
  -s SINGLE_FILE=1 \
  -s ALLOW_MEMORY_GROWTH=1 -s ENVIRONMENT=web,node \
  -s EXPORTED_RUNTIME_METHODS='["FS","callMain"]' \
  -s INVOKE_RUN=0 \
  -I. \
  /tmp/check_main.c runtime.c map.c lib.c type.c \
  -o tools/lsp/check.js

echo "built tools/lsp/check.js ($(stat -c%s tools/lsp/check.js) bytes, $(gzip -c tools/lsp/check.js | wc -c) gzipped)"
