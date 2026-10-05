# src/y/arch/math.s — the machine primitives std/math.y needs and Y cannot
# express. Y has no float-to-long conversion and no way to read a float's
# bits, so every elementary transcendental in the language is waiting on
# these four; they are the whole of the gap between the language and a
# numeric library.
#
# Each one is reached from Y through a `native def` (docs 03-grammar.tex),
# so it is called with the ordinary convention: the argument is pushed, and
# because every one of these is a leaf the argument sits at 8(%rsp) (the
# return address is at 0(%rsp)) and the result comes back in %rax — a float
# as its raw bits, which is what every other Y value is.

# y_sqrt: the IEEE square root. sqrtsd is the hardware's own double-precision
# root, correctly rounded, so this is exact to the last bit rather than an
# approximation: sqrt(+inf) is +inf, sqrt(+0) is +0, and sqrt of a negative
# is the NaN SSE2 produces (that is the IEEE answer, and it raises the
# invalid flag rather than trapping).
y_sqrt:
    mov 8(%rsp), %rax
    movq %rax, %xmm0
    sqrtsd %xmm0, %xmm0
    movq %xmm0, %rax
    ret

# y_to_int: a double's integer part, truncated toward zero — the C cast, not
# a floor and not a round-to-nearest. cvttsd2si is the truncating form.
#
# For a NaN, an infinity, or a magnitude past LONG_MAX it returns the
# "integer indefinite" value 0x8000000000000000 (the most negative long)
# rather than raising anything, which is why the caller checks the result
# rather than trusting it: a silent 0 or a silent -2^63 would turn a
# programming error into a plausible number. std/math.y's to_int turns that
# case into a trap.
y_to_int:
    mov 8(%rsp), %rax
    movq %rax, %xmm0
    cvttsd2si %xmm0, %rax
    ret

# y_fbits: a double's bits as a long, and y_bitsf: a long read back as a
# double. Between them they are the cast Y cannot spell — and the reason a Y
# program can look at an exponent at all. Each is a move: the value is
# already its own bits in %rax.
y_fbits:
    mov 8(%rsp), %rax
    ret
# y_bitsf(x): the same bits as a double. The movq out and back are what makes
# this a function rather than nothing: the float must be in an xmm register
# for anything to treat it as one.
y_bitsf:
    mov 8(%rsp), %rax
    movq %rax, %xmm0
    movq %xmm0, %rax
    ret
# y_int_trap: a double that has no integer part a long can hold. The cast
# cannot report it (cvttsd2si answers with the "integer indefinite" value and
# raises nothing), so the Y layer checks and comes here to stop with a message
# that says what happened.
y_int_trap:
    mov $1, %rax
    mov $1, %rdi
    lea ystr_int(%rip), %rsi
    mov $ystr_int_end-ystr_int, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
