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

# y_len_stop: the exit half of std/math.y's equal-length rule (its message goes
# through eputs, which is ordinary Y; only the stop is machine code). Split the
# same way as y_int_trap, for the same reason: a `void` native cannot fall off
# its end into whatever follows.
y_len_stop:
    mov $231, %rax
    mov $1, %rdi
    syscall

# ── the two form probes ─────────────────────────────────
#
# Neither of these is used by std/math.y. They exist because there is no other
# way to check the encoder's SSE forms: every one of them assembles whether or
# not it means what the mnemonic says, and the one that does not still produces
# a plausible number. That is the trap the F2 prefix is -- `movsd` without it is
# `movups` (sixteen bytes, two lanes) and `mulsd` without it is `mulps`, so a
# kernel written with the packed form multiplies two doubles at once and returns
# something plausible and wrong. `make asm-check` cannot see it, because GNU as
# accepts the packed spelling as an alias; so the gate has to run the thing.
# The shaker drops both blocks from a binary that does not call them.
#
# A NOTE ON COMMENT STYLE, because it cost real time: arch_asm_lines drops a
# line only when its FIRST byte is `#`, so a comment trailing an instruction
# reaches the assembler and is read as an operand. The symptom is `L###: bad
# operand` on a line whose opcode the prelude uses everywhere, which sends the
# reader looking for a fault in the new form rather than in the comment.
# `make asm-check` passes such a line, because GNU as reads trailing comments
# and ycc's assembler does not. So every comment here is flush left and on its
# own line, which is what the other two arch .s files already do -- neither has
# a single indented `#`.
#
# ysf_tab: the four constants, as ONE block under ONE label. A kernel reads them
# as ysf_tab+0, +8, +16 and +24, and a label per constant would cost the shaker
# ~2K instructions of label-map fixpoint each, forever, on every compile (the
# same reason `label+N(%rip)` exists at all). The block lives HERE rather than in
# arch_consts because math.s is shaken block by block: a program that calls no
# probe drops these 32 bytes along with the probes, whereas a table in
# arch_consts is kept by every program that reaches it at all.
#
# 2.0, 0.5, 0.25 and 4.0 -- all exactly representable, which is what lets the
# fixture state its expected value as arithmetic instead of as a table.
ysf_tab:
    .quad 4611686018427387904
    .quad 4602678819172646912
    .quad 4598175219545276416
    .quad 4616189618054758400
#
# y_sse_forms(a, b): (a*b)*c0 + c1 - c2, all over c3 -- with the last three
# steps applied to the value that has been through a stack slot, so the store
# and the load are on the critical path and a broken one changes the answer
# instead of going unnoticed. With a=3, b=5 and the four constants in
# arch_consts that is (15*2 + 0.5 - 0.25)/4 = 30.25/4 = 7.5625 exactly: every
# step is a binary fraction, so the expected value is arithmetic rather than a
# table. The notes below name the operand shape each instruction is here to
# exercise.
y_sse_forms:
    mov 16(%rsp), %rax
    mov 8(%rsp), %rcx
# xmm0 = a, xmm1 = b
    movq %rax, %xmm0
    movq %rcx, %xmm1
# xmm2 = b, then a*b: the register-to-register forms
    movsd %xmm1, %xmm2
    mulsd %xmm0, %xmm2
# the register-with-a-memory-source forms, which is how a kernel reads its
# coefficient table without spending a separate load on every term
    mulsd ysf_tab+0(%rip), %xmm2
# a store and a load through a stack slot: the two remaining movsd forms
    sub $16, %rsp
    movsd %xmm2, 8(%rsp)
    movsd 8(%rsp), %xmm3
    add $16, %rsp
# the rest of the arithmetic, on what came back
    addsd ysf_tab+8(%rip), %xmm3
    subsd ysf_tab+16(%rip), %xmm3
    divsd ysf_tab+24(%rip), %xmm3
    movq %xmm3, %rax
    ret
#
# y_sse_flags(a, b): the conditions a float kernel tests, one bit each, so one
# call checks all five. ucomisd compares the SOURCE against the destination, so
# `ucomisd %xmm0, %xmm1` asks whether b is above a. What it leaves in the flags
# (Intel SDM): unordered -- an operand was a NaN -- sets ZF, PF and CF; above
# sets none of them; below sets CF; equal sets ZF. So `jbe` also catches
# unordered, because CF is set there: one branch says "too small, or NaN", which
# is the first test every float function makes and the reason a kernel cannot
# use `jb` there. Each test is a two-instruction pair -- the branch skips its own
# `or`, so a taken condition falls into it and an untaken one does not -- rather
# than one `or` under a shared tail, because the conditions overlap (above
# implies above-or-equal) and a shared tail would leave the second bit unset.
# The overflow pair is deliberately absent: an SSE comparison clears OF whatever
# it found, so `jo` after one could never fire, and a fixture gating it would be
# gating nothing.
y_sse_flags:
    mov 16(%rsp), %rax
    mov 8(%rsp), %rcx
    movq %rax, %xmm0
    movq %rcx, %xmm1
    xor %eax, %eax
    ucomisd %xmm0, %xmm1
# bit 0: parity set, unordered, so a NaN was one of the two operands
    jp ysf_p
    jnp ysf_np
    jmp ysf_x
ysf_p:
    or $1, %rax
    jmp ysf_x
ysf_np:
# bit 1: parity clear, the other side of the same question
    or $2, %rax
ysf_x:
# bit 2: CF=0, ZF=0, so b above a
    ja ysf_a
    jmp ysf_ae
ysf_a:
    or $4, %rax
ysf_ae:
# bit 3: CF=0, so b above a, b equal to a, or unordered
    jae ysf_ae_t
    jmp ysf_b
ysf_ae_t:
    or $8, %rax
ysf_b:
# bit 4: CF=1 or ZF=1, so b below a, b equal to a, or unordered
    jbe ysf_b_t
    ret
ysf_b_t:
    or $16, %rax
    ret

# y_exp: exp(x). Generated from src/y/std/math.y's exp by
# test/math/gen_kernel.py-style reading of its own constants -- do not retype
# the table, because the whole constraint is that this returns the same double
# as that function, and a table typed by hand can disagree with it silently.
#
# The operation sequence is the Y line for line, which is what makes the bits
# match: the same multiplies and subtracts in the same order, the same two
# Horner chains for the split kernel, the same ldexp including its big steps
# and its doubling loop for a subnormal answer. `t310`-style: the oracle is
# math.exp itself and every call site compares bits.
#
# Argument at 8(%rsp) (the last and only one), answer's bits in %rax.
y_exp:
    mov 8(%rsp), %rax
# xmm2 = x, kept for the reduction
    movq %rax, %xmm2                 
    movq %xmm2, %xmm0
# if (x != x) return x: the operand compared with itself is unordered exactly
# when it is a NaN, and unordered is the only answer with PF set.
    ucomisd %xmm2, %xmm2
    jp yexp_ret
# if (x > exp_hi) return +inf
    ucomisd yexp_tab+0(%rip), %xmm2
    ja yexp_inf
# if (x < exp_lo) return +0.0
    ucomisd yexp_tab+8(%rip), %xmm2
    jb yexp_zero

# n = to_int(floor(x*log2e + 0.5)). The truncating convert is a floor only
# when the value it truncated was already at or below the integer; one less
# when the truncation rounded UP, which is when the truncated value is
# GREATER than what it came from -- a negative argument, or one in 1.0..1.5.
    mulsd yexp_tab+16(%rip), %xmm0
# t = x*log2e + 0.5
    addsd yexp_tab+40(%rip), %xmm0  
# trunc(t)
    cvttsd2si %xmm0, %rax            
    cvtsi2sd %rax, %xmm1
# trunc(t) against t
    ucomisd %xmm0, %xmm1            
    jbe yexp_k_ok
# it rounded up: one less
    sub $1, %rax                     
yexp_k_ok:
# xmm1 = nf
    cvtsi2sd %rax, %xmm1             

# r = (x - nf*ln2_hi) - nf*ln2_lo: ln2 in two pieces so the reduction keeps
# the low bits, which is what one rounding of nf*ln2 would have lost.
    movsd %xmm1, %xmm3
    mulsd yexp_tab+24(%rip), %xmm3
    subsd %xmm3, %xmm2
    movsd %xmm1, %xmm3
    mulsd yexp_tab+32(%rip), %xmm3
# xmm2 = r
    subsd %xmm3, %xmm2              

# k and f2: 2^1024 is an overflow and round(x*log2e) reaches 1024 for every x
# above 709.4, so the last whole ln2 stays in r and its factor of two is put
# in by hand -- which also keeps r inside the kernel's range.
# rcx = k
    mov %rax, %rcx                   
# f2 = 1.0
    movsd yexp_tab+48(%rip), %xmm6  
    cmp $1023, %rcx
    jle yexp_f2_ok
    sub $1, %rcx
# f2 = 2.0
    movsd yexp_tab+56(%rip), %xmm6  
yexp_f2_ok:

# P = poly_split(exp_k, exp_kl, r): two Horner chains over the split table,
# so a term whose low part would fall off the end of a double is kept, and
# one add at the end brings the two halves together.
    movsd yexp_tab+176(%rip), %xmm4
    movsd yexp_tab+280(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+168(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+272(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+160(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+264(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+152(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+256(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+144(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+248(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+136(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+240(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+128(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+232(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+120(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+224(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+112(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+216(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+104(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+208(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+96(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+200(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+88(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+192(%rip), %xmm5
    mulsd %xmm2, %xmm4
    addsd yexp_tab+80(%rip), %xmm4
    mulsd %xmm2, %xmm5
    addsd yexp_tab+184(%rip), %xmm5
    addsd %xmm5, %xmm4

# v = f2 * (1 + r*(1 + r*P))
    movsd %xmm2, %xmm3
    mulsd %xmm4, %xmm3
    addsd yexp_tab+48(%rip), %xmm3
    mulsd %xmm2, %xmm3
    addsd yexp_tab+48(%rip), %xmm3
    mulsd %xmm6, %xmm3

# ldexp(v, k), as written in std/math.y: the big steps first, so that after
# them the answer may already be 0 or an infinity and there is nothing left
# to do exactly. 2^1022 rather than 2^1023: one more step than the range
# needs, so a step never overflows on its own.
# ldexp(v, k), as written in std/math.y: the big steps first, so that after
# them the answer may already be 0 or an infinity and there is nothing left
# to do exactly. 2^1022 rather than 2^1023: one more step than the range
# needs, so a step never overflows on its own.
# rdx = the value
    movq %xmm3, %rdx                 
    cmp $1022, %rcx
    jl yexp_ld_up_done
    movq %rdx, %xmm4
    mulsd yexp_tab+64(%rip), %xmm4
    movq %xmm4, %rdx
    sub $1022, %rcx
yexp_ld_up_done:
    cmp $-1022, %rcx
    jg yexp_ld_dn_done
    movq %rdx, %xmm4
    mulsd yexp_tab+72(%rip), %xmm4
    movq %xmm4, %rdx
    add $1022, %rcx
yexp_ld_dn_done:
# f = exp_field(r) = the pattern's exponent field
    mov %rdx, %rax
    shr $52, %rax
    and $2047, %rax
# if (f == 0 || f + k < 1) the mantissa has to shift too, and one doubling at
# a time is how that is exact -- which is also the subnormal case, where the
# field is 0 and every step is a doubling.
    test %rax, %rax
    jz yexp_ld_shift
    mov %rax, %r8
    add %rcx, %r8
    cmp $1, %r8
    jl yexp_ld_shift
# else if (k != 0): k * 2^52 added to the bits is k added to the field, so the
# sign comes off first (a negative pattern would put a 1 at the top of the
# field and scale the wrong way) and goes back on after.
    test %rcx, %rcx
    jz yexp_ld_done
# The sign that matters is the VALUE's. `js` after the `shl` would be reading
# k's -- the first version did exactly that, so every x below about zero
# (half the range) took the negative path and had 2^63 added to a pattern
# that was already positive.
    test %rdx, %rdx
    js yexp_ld_neg
    mov %rcx, %r8
    shl $52, %r8
    add %r8, %rdx
    jmp yexp_ld_done
yexp_ld_neg:
    mov %rcx, %r8
    shl $52, %r8
    add %r8, %rdx
# shifted + sign_bit(). 2^63 is one past the largest long, so it is a movabs
# rather than an immediate: `mov $4611686018427387904, %r8` cannot be spelled,
# and `mov $-1, %r8; shl $63, %r8` would be one instruction longer for the
# same bits.
    mov $-9223372036854775808, %r8
    add %r8, %rdx
    jmp yexp_ld_done
yexp_ld_shift:
    test %rcx, %rcx
    jz yexp_ld_done
    cmp $0, %rcx
    jg yexp_ld_up_loop
# 0.5
    movsd yexp_tab+40(%rip), %xmm7  
    jmp yexp_ld_loop
yexp_ld_up_loop:
# 2.0
    movsd yexp_tab+56(%rip), %xmm7  
yexp_ld_loop:
    movq %rdx, %xmm4
    mulsd %xmm7, %xmm4
    movq %xmm4, %rdx
    add $1, %rcx
    jnz yexp_ld_loop
yexp_ld_done:
    mov %rdx, %rax
yexp_ret:
    ret
yexp_inf:
# +inf
    mov $9218868437227405312, %rax  
    ret
yexp_zero:
# +0.0
    xor %eax, %eax                   
    ret

# yexp_tab: exp's constants and its split kernel, one label for the lot (a
# label per entry costs the shaker ~2K instructions of fixpoint each, on
# every compile). Read as yexp_tab+N(%rip), N = 8*index.
yexp_tab:
# ehi
    .quad 4649454530587146735  
# elo
    .quad -4573606559926636463  
# l2e
    .quad 4609176140021203710  
# ln2h
    .quad 4604418534311723008  
# ln2l
    .quad 4461442080421002358  
# half
    .quad 4602678819172646912  
# one
    .quad 4607182418800017408  
# two
    .quad 4611686018427387904  
# p1022
    .quad 9209861237972664320  
# n1022
    .quad 4503599627370496  
# k0
    .quad 4602678819172646912  
# k1
    .quad 4595172819793696085  
# k2
    .quad 4586165620538955093  
# k3
    .quad 4575957461383581969  
# k4
    .quad 4564047942368980032  
# k5
    .quad 4551452160554010291  
# k6
    .quad 4537941361672559128  
# k7
    .quad 4523617214241652872  
# k8
    .quad 4508805059821815664  
# k9
    .quad 4493156636345600448  
# k10
    .quad 4477124829796050474  
# k11
    .quad 4460198783048879773  
# k12
    .quad 4444300467281662528  
# kl0
    .quad 4224632360921249723  
# kl1
    .quad 4351978422624852795  
# kl2
    .quad 4342982412625320984  
# kl3
    .quad -4897883672244480899  
# kl4
    .quad 4318414372254905642  
# kl5
    .quad 4309670800024669605  
# kl6
    .quad 4292170439773447773  
# kl7
    .quad -4948112769179017817  
# kl8
    .quad -4959816150548831358  
# kl9
    .quad 4248733497338995685  
# kl10
    .quad -4989209265562316451  
# kl11
    .quad 4211823218516068692  
# kl12
    .quad 4194903912182756409  

# ── the bulk kernels ──────────────────────────────────────────────────────
#
# Six loops over `[float]`, which is what std/math.y's array tier is: the plain
# sum, the dot product, an in-place scale and axpy, and the two extremes. In Y
# each is a `while` with a bounds check and an index add per element; here the
# pointer walks and a counter comes down.
#
# The contract is BIT-IDENTITY with the Y version -- same order of operations,
# same rounding, so the result is the same double. That is why y_sum starts its
# accumulator at +0.0 rather than at the first element (0.0 + a[0] is not a[0]
# when a[0] is -0.0), why y_dot multiplies before it adds, and why the two
# extremes use a comparison rather than minsd/maxsd (those return the SECOND
# operand when either side is a NaN, which would let a NaN into the running
# extreme; Y's `a[i] < m` is false for a NaN, so a NaN never enters).
#
# Each takes the array's data pointer and its length, never the array: the
# header is four words and the elements are elsewhere (NATIVE.md, "Arrays"), so
# the caller passes `a.ptr` and `len(a)`. A kernel reads n >= 1 -- the wrapper
# in std/math.y answers the empty case in Y, where `nan` lives.

# y_sum(p, n): p = 0.0, then p += a[i] in order.
y_sum:
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rcx
# xmm0 = +0.0, the accumulator the Y `let s = 0.0` starts from
    xor %eax, %eax
    movq %rax, %xmm0
    test %rcx, %rcx
    jle ysum_done
ysum_loop:
    addsd (%rsi), %xmm0
    add $8, %rsi
    dec %rcx
    jnz ysum_loop
ysum_done:
    movq %xmm0, %rax
    ret

# y_dot(p, q, n): p = 0.0, then p += a[i] * b[i] in order.
y_dot:
    mov 24(%rsp), %rsi
    mov 16(%rsp), %rdi
    mov 8(%rsp), %rcx
    xor %eax, %eax
    movq %rax, %xmm0
    test %rcx, %rcx
    jle ydot_done
ydot_loop:
# the multiply first, as Y writes it: a[i] * b[i], and multiplication is
# commutative in IEEE, so the operand order does not change the bits
    movsd (%rsi), %xmm1
    mulsd (%rdi), %xmm1
    addsd %xmm1, %xmm0
    add $8, %rsi
    add $8, %rdi
    dec %rcx
    jnz ydot_loop
ydot_done:
    movq %xmm0, %rax
    ret

# y_scale(p, n, k): p[i] *= k, in place. Arguments in source order, so k is the
# LAST one and sits at 8(%rsp).
y_scale:
    mov 24(%rsp), %rsi
    mov 16(%rsp), %rcx
    mov 8(%rsp), %rax
    movq %rax, %xmm1
    test %rcx, %rcx
    jle yscale_done
yscale_loop:
    movsd (%rsi), %xmm0
    mulsd %xmm1, %xmm0
    movsd %xmm0, (%rsi)
    add $8, %rsi
    dec %rcx
    jnz yscale_loop
yscale_done:
    ret

# y_axpy(y, n, k, x): y[i] += k * x[i], in place -- the axpy of numerical
# linear algebra, which is how a vector is accumulated without allocating.
y_axpy:
    mov 32(%rsp), %rsi
    mov 24(%rsp), %rcx
    mov 16(%rsp), %rax
    mov 8(%rsp), %rdi
    movq %rax, %xmm1
    test %rcx, %rcx
    jle yaxpy_done
yaxpy_loop:
    movsd (%rdi), %xmm0
    mulsd %xmm1, %xmm0
    addsd (%rsi), %xmm0
    movsd %xmm0, (%rsi)
    add $8, %rsi
    add $8, %rdi
    dec %rcx
    jnz yaxpy_loop
yaxpy_done:
    ret

# y_min_of(p, n) over n >= 1: the running minimum, and a NaN never enters it.
#
# `ucomisd %xmm1, %xmm0` compares the DESTINATION (m) against the source (a[i]),
# so `ja` -- CF=0 and ZF=0 -- is exactly "m is strictly above a[i]", which is
# when Y's `a[i] < m` would have replaced it. Everything else keeps m: a[i] above
# m sets CF, equality sets ZF, and an unordered comparison (a NaN on either side)
# sets CF as well, so a NaN cannot enter the running minimum.
#
# NOT `jb`: `jb` is CF=1 on its own, and CF is 1 for the unordered case too, so
# `jb` would let a NaN in -- which is what the first version did. And not
# `minsd`: that returns the SECOND operand when either side is a NaN, which is
# the opposite rule again.
y_min_of:
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rcx
    test %rcx, %rcx
    jle ymin_first
    movsd (%rsi), %xmm0
    add $8, %rsi
    dec %rcx
    jz ymin_done
ymin_loop:
    movsd (%rsi), %xmm1
    ucomisd %xmm1, %xmm0
    ja ymin_take
    add $8, %rsi
    dec %rcx
    jnz ymin_loop
    jmp ymin_done
ymin_take:
    movsd %xmm1, %xmm0
    add $8, %rsi
    dec %rcx
    jnz ymin_loop
ymin_done:
    movq %xmm0, %rax
    ret
# n <= 0: the wrapper never does this, and there is no first element to read.
ymin_first:
    xor %eax, %eax
    ret

# y_max_of(p, n) over n >= 1: the same shape with the operands the other way
# round, so `ja` again means "a[i] is strictly above m".
y_max_of:
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rcx
    test %rcx, %rcx
    jle ymax_first
    movsd (%rsi), %xmm0
    add $8, %rsi
    dec %rcx
    jz ymax_done
ymax_loop:
    movsd (%rsi), %xmm1
    ucomisd %xmm0, %xmm1
    ja ymax_take
    add $8, %rsi
    dec %rcx
    jnz ymax_loop
    jmp ymax_done
ymax_take:
    movsd %xmm1, %xmm0
    add $8, %rsi
    dec %rcx
    jnz ymax_loop
ymax_done:
    movq %xmm0, %rax
    ret
ymax_first:
    xor %eax, %eax
    ret
