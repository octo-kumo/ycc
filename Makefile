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

.PHONY: all clean valgrind test test-compile
