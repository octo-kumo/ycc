#!/bin/bash
# Build the Y->AssemblyScript emitter as a browser wasm module.
# Pipeline: emit_main.y --(ycc1)--> C --(emcc)--> single-file JS+wasm.
# Output: tools/as/emit-as.js  (~200KB, wasm embedded as base64).
set -e
cd "$(dirname "$0")/../.."

# 1. The C compiler emits C from the Y emitter driver.
#    NOTE: historically ycc1 (the old C-emitting ycc) was used here because it
#    compiled the emitter correctly while the C compiler miscompiled it. ycc
#    is native-only now, so this step uses ./yboot -S; if the emitter
#    misbehaves, that old codegen bug is the prime suspect.
echo "[1/2] compiler -S: emit_main.y -> C"
./yboot -S tools/as/emit_main.y -o /tmp/emit_main.c

# 2. emcc compiles the emitted C + runtime to a single-file browser module.
echo "[2/2] emcc: C -> wasm (single file)"
emcc -O2 -s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME=createEmitAS \
  -s SINGLE_FILE=1 \
  -s ALLOW_MEMORY_GROWTH=1 -s ENVIRONMENT=web,node \
  -s EXPORTED_RUNTIME_METHODS='["FS","callMain"]' \
  -s INVOKE_RUN=0 \
  -Isrc/c \
  /tmp/emit_main.c src/c/runtime.c src/c/map.c src/c/lib.c src/c/type.c \
  -o tools/as/emit-as.js

echo "built tools/as/emit-as.js ($(stat -c%s tools/as/emit-as.js) bytes, $(gzip -c tools/as/emit-as.js | wc -c) gzipped)"
