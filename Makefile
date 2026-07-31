GCC=gcc
CFLAGS=-Wall -Wextra -std=gnu99 -g -DRUNTIME_DIR='"$(CURDIR)"'
SRCS=$(wildcard *.c)
HDRS=$(wildcard *.h)
OBJS=$(SRCS:.c=.o)
EXEC=compiler

all: $(EXEC)

$(EXEC): $(OBJS)
	$(GCC) $(CFLAGS) -o $@ $^

%.o: %.c $(HDRS)
	$(GCC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(EXEC)

valgrind: $(EXEC)
	valgrind --leak-check=full --quiet ./compiler 

test: $(EXEC)
	./compiler examples/leftfold.y

# Compile an example to a native binary and run it
test-compile: $(EXEC)
	./compiler --compile examples/helloworld.y -o /tmp/hello_bin && /tmp/hello_bin

# Generate embedded_runtime.inc (bakes runtime.c/h into a binary as C constants)
embedded_runtime.inc: $(EXEC) runtime.c runtime.h
	printf '#include "runtime.h"\nint main(void){ return y_gen_embedded_runtime(".", "."); }\n' > /tmp/gen_inc.c
	$(GCC) -O2 -std=gnu99 -I. -o /tmp/gen_inc /tmp/gen_inc.c runtime.c -lm
	/tmp/gen_inc

# Build the self-hosted ycc as a fully self-contained binary (no YCC_RUNTIME_DIR
# needed to compile or run). Bootstraps: C compiler -> gen0 -> fixed point.
ycc-selfcontained: embedded_runtime.inc $(EXEC)
	./compiler -S -o /tmp/ycc_gen0.c ycc/ycc.y
	$(GCC) -O2 -std=gnu99 -I. -DY_EMBED_RUNTIME -o /tmp/ycc_gen0 /tmp/ycc_gen0.c runtime.c -lm
	cp /tmp/ycc_gen0 /tmp/ycc_prev
	for gen in 1 2 3 4; do \
	  rm -rf /tmp/ycc_runtime_* /tmp/ycc_inc; \
	  env -u YCC_RUNTIME_DIR /tmp/ycc_prev --self-contained -c -o /tmp/ycc_gen$$gen ycc/ycc.y || break; \
	  if cmp -s /tmp/ycc_prev /tmp/ycc_gen$$gen; then echo "FIXED POINT gen$$gen"; break; fi; \
	  cp /tmp/ycc_gen$$gen /tmp/ycc_prev; \
	done
	cp /tmp/ycc_prev ycc-selfcontained
	@echo "built ./ycc-selfcontained ($$(stat -c%s ycc-selfcontained) bytes)"

.PHONY: all clean valgrind test test-compile ycc-selfcontained
