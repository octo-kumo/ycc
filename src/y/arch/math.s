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
# y_int_trap and y_len_stop go through the NAMED layer (y_os_write, y_os_exit)
# rather than raw numbers, because this file is embedded in both targets and
# `mov $1,%rax` is write(2) only on Linux: on a PE it is lseek, the trap fell
# through, and `math.to_int(1.0/0.0)` returned a value instead of stopping the
# program (ideas/WINDOWS.md, "math.s is target-blind"). The two labels exist in
# prelude.s and in its Windows half (wsys.s), so calling them is what makes this
# block correct on both -- and the shaker keeps them because this block
# references them. Arguments go on the stack, count pushed last.
y_int_trap:
    mov $1, %rax
    push %rax
    lea ystr_int(%rip), %rax
    push %rax
    mov $ystr_int_end-ystr_int, %rax
    push %rax
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
    add $8, %rsp

# y_len_stop: the exit half of std/math.y's equal-length rule (its message goes
# through eputs, which is ordinary Y; only the stop is machine code). Split the
# same way as y_int_trap, for the same reason: a `void` native cannot fall off
# its end into whatever follows.
y_len_stop:
    mov $1, %rax
    push %rax
    call y_os_exit
    add $8, %rsp

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

# y_test_imm(n) -> what `test` leaves in the flags, as bits, so one call checks
# the immediate form end to end. The form has two encodings that differ by one
# byte -- F7 /0 reads the register the instruction names, F6 /0 reads %al and
# ignores REX.W -- and both are legal, so `make asm-check` cannot tell them
# apart and neither can a fixture on a small index: `test $1, %rax` answered the
# same as `test $1, %al` for every value under 256, which is why a kernel that
# asked "which of these four" carried a wrong flag test unnoticed. Two
# immediates, because one cannot cover both widths of what the instruction has
# to report:
#   $257 = 2^8+1 does not fit an imm8, so the F6 encoding cannot even be
#     written for it -- reaching these bits at all says the operand's width was
#     read. It gives ZF (was the AND zero) and PF (the parity of its low byte).
#   $-1 sign-extends to all ones, so the AND is n itself and SF is n's sign --
#     the one flag $257 can never set, because a positive immediate cannot make
#     a negative result.
# Bit 2 is CF, and it is always 0: TEST is an AND, so it clears CF and OF
# whatever the operands are (Intel SDM). Reporting the cleared flag is the point
# -- it is what says the instruction really is a TEST and not a CMP, which for
# these same operands would set it (0 < 257, so CMP $257, %rax leaves CF=1).
# Bit 0 ZF, bit 1 SF, bit 2 CF, bit 3 PF, bits 4 and up the AND itself. The
# first test's flags are read before the second one overwrites them.
y_test_imm:
    mov 8(%rsp), %rax
    xor %ecx, %ecx
    test $257, %rax
    jnz yti_zf
    or $1, %rcx
yti_zf:
    jb yti_cf
    jmp yti_cf_n
yti_cf:
    or $4, %rcx
yti_cf_n:
    jp yti_pf
    jnp yti_pf_n
yti_pf:
    or $8, %rcx
yti_pf_n:
    test $-1, %rax
    jns yti_sf_n
    or $2, %rcx
yti_sf_n:
# the AND goes in ABOVE the four flag bits, so it is shifted up four first --
# or-ed in at bit 0 it would overwrite the flags it reports beside
    mov %rax, %rdx
    and $257, %rdx
    shl $4, %rdx
    or %rdx, %rcx
    mov %rcx, %rax
    ret

# y_exp: exp(x). Generated from src/y/std/math.y's exp by
# `ytest math-gen exp`, which reads its own constants -- do not retype
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

# y_log: log(x), x > 0. Generated by `ytest math-gen log` from src/y/std/math.y's
# own log -- do not retype the table (see that file's note). The sequence is
# the Y's line for line, which is what makes the answer the same double rather
# than a near one.
#
# Argument at 8(%rsp) (the last and only one), answer's bits in %rax.
y_log:
    mov 8(%rsp), %rax
# xmm2 = x
    movq %rax, %xmm2                 
# if (x != x || x < 0.0) return nan. The self-comparison is the NaN test (PF is
# set only for the unordered result) and `jb` is the x < 0 one: x is not a NaN
# by the time it is tested, so CF=1 means below zero and nothing else.
    ucomisd %xmm2, %xmm2
    jp ylog_nan
    movsd ylog_tab+40(%rip), %xmm8
# flags for x against zero
    ucomisd %xmm8, %xmm2              
    jb ylog_nan
# if (x == 0.0) return -inf. +0.0 and -0.0 both compare equal to zero, which is
# what the Y's `x == 0.0` does, so both answer -inf.
# zero is still in xmm8
    ucomisd %xmm8, %xmm2              
    je ylog_ninf
# if (is_inf(x)) return +inf. At this point x >= 0, so it is +inf or nothing.
    movsd %xmm2, %xmm0
    ucomisd ylog_tab+48(%rip), %xmm0
    je ylog_pinf

# frexp: the mantissa is this mantissa at exponent 1022, in BITS because there
# is no float-to-long conversion here, and the field carries a BIAS of 1023.
# The sign comes off and goes back on as the exponent's sign -- a negative x's
# pattern would put a 1 at the top of an 11-bit field and answer with a
# positive fraction -- but x is positive here (the x < 0 case returned nan), so
# there is nothing to put back.
# r = x, the Y's `let r = x`
    movq %xmm2, %xmm5                 
    mov %rax, %rdx
    shr $52, %rdx
# the field, 0 for a subnormal
    and $2047, %rdx                   
# the guard counter
    xor %ecx, %ecx                    
    test %rdx, %rdx
    jnz ylog_norm_done
# A subnormal has no implicit leading bit, so it is doubled until the field is
# not 0. The Y's loop also tests `r != 0.0`; x is not zero here (the zero case
# returned above) and doubling a nonzero never reaches zero, so that test has
# nothing to catch.
ylog_norm:
    cmp $60, %rcx
    jge ylog_norm_done
    movq %xmm5, %rax
    shr $52, %rax
    and $2047, %rax
    test %rax, %rax
    jnz ylog_norm_done
    movsd %xmm5, %xmm8
# r = r * 2.0
    mulsd ylog_tab+32(%rip), %xmm8          
    movsd %xmm8, %xmm5
    add $1, %rcx
    jmp ylog_norm
ylog_norm_done:
# r's bits
    movq %xmm5, %rax                   
    mov %rax, %rdx
    shr $52, %rdx
# the field of r, before the mask
    and $2047, %rdx                   
    mov $4503599627370495, %r10
# the mantissa's 52 bits
    and %r10, %rax                    
    mov $4602678819172646912, %r10
# at exponent 1022, so in [0.5, 1)
    or %r10, %rax                     
# m
    movq %rax, %xmm2                   
    sub $1022, %rdx
# e = field - 1023 - guard
    sub %rcx, %rdx                    

# if (m < inv_sqrt2) { m = m*2; e = e-1 }, so the kernel's |z| stays at
# sqrt(2)-1 rather than reaching 1.
    movsd ylog_tab+0(%rip), %xmm8
# m against 1/sqrt(2)
    ucomisd %xmm8, %xmm2              
    jae ylog_m_ok
    movsd %xmm2, %xmm8
    mulsd ylog_tab+32(%rip), %xmm8
    movsd %xmm8, %xmm2
    sub $1, %rdx
ylog_m_ok:
# xmm6 = ef, the exponent as a double
    cvtsi2sd %rdx, %xmm6              

# log_z(m): z = (m-1)/(m+1), and z_lo the error of that division. m-1 is exact
# (Sterbenz) and the division rounds once, but m+1 rounds too and its half an
# ulp of 2 is a WHOLE ulp of z, which would be the whole budget. bb = den - m
# and derr = (m - (den - bb)) + (1.0 - bb) is the denominator's residual by
# two_sum, and one more divide turns it into z's.
    movsd %xmm2, %xmm0
# num = m - 1.0
    subsd ylog_tab+24(%rip), %xmm0          
    movsd %xmm2, %xmm1
# den = m + 1.0
    addsd ylog_tab+24(%rip), %xmm1          
    movsd %xmm1, %xmm8
# bb = den - m
    subsd %xmm2, %xmm8                
    movsd %xmm1, %xmm3
# den - bb
    subsd %xmm8, %xmm3                
    movsd %xmm2, %xmm4
# m - (den - bb)
    subsd %xmm3, %xmm4                
    movsd ylog_tab+24(%rip), %xmm3
# 1.0 - bb
    subsd %xmm8, %xmm3                
# derr
    addsd %xmm3, %xmm4                
# z = num/den
    divsd %xmm1, %xmm0                
    movsd %xmm0, %xmm7
# z * derr
    mulsd %xmm4, %xmm7                
    movsd ylog_tab+40(%rip), %xmm8
# 0.0 - z*derr
    subsd %xmm7, %xmm8                
# xmm8 = z_lo
    divsd %xmm1, %xmm8                
# z = z + z_lo
    addsd %xmm8, %xmm0                
    movsd %xmm0, %xmm3
# w = z*z
    mulsd %xmm0, %xmm3                

# P = poly_split(log_k, log_kl, w): two Horner chains over the split table, so
# a term whose low part would fall off the end of a double is kept.
    movsd ylog_tab+144(%rip), %xmm2
    movsd ylog_tab+232(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+136(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+224(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+128(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+216(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+120(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+208(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+112(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+200(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+104(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+192(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+96(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+184(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+88(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+176(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+80(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+168(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+72(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+160(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+64(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+152(%rip), %xmm9
# P
    addsd %xmm9, %xmm2                

# (z*(2 + w*P)) + (ef*ln2_hi) + (ef*ln2_lo), in that order: the small z part
# first and each large half at its own scale, which is the only order that
# keeps z's low bits.
    movsd %xmm3, %xmm7
# w*P
    mulsd %xmm2, %xmm7                
# 2 + w*P
    addsd ylog_tab+32(%rip), %xmm7          
# z*(2 + w*P)
    mulsd %xmm7, %xmm0                
    movsd %xmm6, %xmm7
    mulsd ylog_tab+8(%rip), %xmm7
    addsd %xmm7, %xmm0
    movsd %xmm6, %xmm7
    mulsd ylog_tab+16(%rip), %xmm7
    addsd %xmm7, %xmm0
    movq %xmm0, %rax
    ret
ylog_nan:
# The module's `nan` is `0.0 / 0.0`, so the NaN is COMPUTED rather than stored:
# a table entry would have to be written down, and the default NaN carries the
# sign bit (0xFFF8000000000000), so the one you would write from memory --
# 0x7FF8000000000000 -- is a different double from the one the Y returns. One
# divide is the same instruction the module itself runs.
    movsd ylog_tab+40(%rip), %xmm0
    divsd %xmm0, %xmm0
    movq %xmm0, %rax
    ret
ylog_pinf:
    movsd ylog_tab+48(%rip), %xmm0
    movq %xmm0, %rax
    ret
ylog_ninf:
    movsd ylog_tab+56(%rip), %xmm0
    movq %xmm0, %rax
    ret


# ylog_tab: log's constants and its split kernel, one label for the lot (a label per entry costs the shaker ~2K instructions of fixpoint each, on every compile). Read as ylog_tab+N(%rip), N = 8*index.
ylog_tab:
# isqrt2
    .quad 4604544271217802189
# ln2h
    .quad 4604418534311723008
# ln2l
    .quad 4461442080421002358
# one
    .quad 4607182418800017408
# two
    .quad 4611686018427387904
# zero
    .quad 0
# pinf
    .quad 9218868437227405312
# ninf
    .quad -4503599627370496
# k0
    .quad 4604180019048437077
# k1
    .quad 4600877379321698714
# k2
    .quad 4598818590920615058
# k3
    .quad 4597174419628082837
# k4
    .quad 4595718710657656664
# k5
    .quad 4594710912133774153
# k6
    .quad 4593971860467439317
# k7
    .quad 4593141712144674538
# k8
    .quad 4592252363128509348
# k9
    .quad 4591453837607945118
# k10
    .quad 4591948500040643857
# kl0
    .quad 4360985639274028627
# kl1
    .quad -4865687334264938427
# kl2
    .quad 4357937166964838393
# kl3
    .quad -4868503268900987237
# kl4
    .quad -4871988952630025102
# kl5
    .quad -4868899670943794174
# kl6
    .quad 4343404781781428020
# kl7
    .quad -4874664473233528198
# kl8
    .quad -4884447823890100137
# kl9
    .quad 4337203409320955446
# kl10
    .quad 4344181363242323652

# The trigonometry: sin and cos, one body for both. GENERATED by
# `ytest math-gen sin` from src/y/std/math.y's own constants -- do not retype
# the table (see that file's note). The sequence is the Y's line for line,
# which is what makes the answers the same doubles rather than near ones.
#
# The two entry blocks are two instructions each. The shake_refs fall-through
# keeps ysincos_go for either one, so a program that calls only sin carries only
# sin's entry, and one that calls both carries the arithmetic once.
#
# Argument at 8(%rsp) (the last and only one), answer's bits in %rax.
y_sin:
# sin
    xor %r11, %r11                    
    jmp ysincos_go
y_cos:
# cos
    mov $1, %r11                       
ysincos_go:
    mov 8(%rsp), %rax
# xmm9 = x
    movq %rax, %xmm9                  
# if (x != x || is_inf(x)) return nan. The self-comparison is the NaN test --
# PF is set only for the unordered result -- and the two infinities are
# compared against, because an infinite self-comparison is EQUAL and not
# unordered, so the same trick that finds a NaN cannot find an infinity.
    ucomisd %xmm9, %xmm9
    jp ysincos_nan
    movsd ysincos_tab+96(%rip), %xmm0
    ucomisd %xmm0, %xmm9
    je ysincos_nan
    movsd ysincos_tab+104(%rip), %xmm0
    ucomisd %xmm0, %xmm9
    je ysincos_nan
# if (x >= -pi_over_4 && x <= pi_over_4) then r = x and n = 0, which falls into
# the same kernel and the same selection: q = 0, so sin takes s and cos takes c,
# with no sign to apply. The Y returns sin_cos_k(x) directly here and the two
# paths agree, which is worth saying because a smaller argument does not need
# a reduction only because pi/4 is the point where the kernel's argument is
# still short enough to be exact.
    movsd ysincos_tab+48(%rip), %xmm0
    ucomisd %xmm0, %xmm9
    jl ysincos_reduce
    movsd ysincos_tab+40(%rip), %xmm0
    ucomisd %xmm0, %xmm9
    jg ysincos_reduce
# r = x
    movsd %xmm9, %xmm3                 
# n = 0
    xor %r10, %r10                    
    jmp ysincos_kernel
ysincos_reduce:
# n = to_int(floor(x*two_over_pi + 0.5))
    movq %xmm9, %xmm0
    mulsd ysincos_tab+0(%rip), %xmm0
# t
    addsd ysincos_tab+56(%rip), %xmm0           
    cvttsd2si %xmm0, %rax
    cvtsi2sd %rax, %xmm1
    ucomisd %xmm0, %xmm1
    jbe ysincos_n_ok
    sub $1, %rax
ysincos_n_ok:
# n
    mov %rax, %r10                      
# nf
    cvtsi2sd %rax, %xmm10              
# r = rem_pio2(x, n). The four products of n with the four pieces of pi/2 are
# taken together, and two of them are compensated: n*pio2_1 needs more than 53
# bits once n passes 2^21 and n*pio2_1t once n passes 2^10, while the other two
# are 3.5e-27 and below, where the rounding is twenty orders under the answer's
# last bit however large n grows. That is why there are two prod_err calls and
# not four.
    movsd %xmm10, %xmm11
# p1
    mulsd ysincos_tab+8(%rip), %xmm11          
    movsd %xmm10, %xmm12
# p1t
    mulsd ysincos_tab+16(%rip), %xmm12         
    movsd %xmm10, %xmm13
# p2
    mulsd ysincos_tab+24(%rip), %xmm13          
    movsd %xmm10, %xmm14
# p2t
    mulsd ysincos_tab+32(%rip), %xmm14         
    movsd %xmm10, %xmm0
    movsd ysincos_tab+8(%rip), %xmm1
    movsd %xmm11, %xmm8
    call ysincos_prod_err
# err, the first half
    movsd %xmm0, %xmm15                
    movsd %xmm10, %xmm0
    movsd ysincos_tab+16(%rip), %xmm1
    movsd %xmm12, %xmm8
    call ysincos_prod_err
# err
    addsd %xmm0, %xmm15                
# ((((x - p1) - p1t) - p2) - p2t) - err, one subtraction at a time: the sum of
# the four pieces is what has to be small, and only a running difference keeps
# it that way.
    movsd %xmm9, %xmm0
    subsd %xmm11, %xmm0
    subsd %xmm12, %xmm0
    subsd %xmm13, %xmm0
    subsd %xmm14, %xmm0
    subsd %xmm15, %xmm0
# r
    movsd %xmm0, %xmm3                 
ysincos_kernel:
# sin_cos_k(r): s = r*(1 + r*r*poly_split(sin_k, sin_kl, r*r)) and
# c = 1.0 - w*poly_split(cos_k, cos_kl, w) with w = r*r. The Y computes r*r
# twice, once for the kernel's argument and once for the multiply, and both
# are the same double, so it is computed once here.
    movsd %xmm3, %xmm0
# w = r*r
    mulsd %xmm3, %xmm0                 
# w again, for the cos kernel
    movsd %xmm0, %xmm1                 
# sin's P, high
    movsd ysincos_tab+152(%rip), %xmm2        
# sin's P, low
    movsd ysincos_tab+200(%rip), %xmm4       
    mulsd %xmm0, %xmm2
    addsd ysincos_tab+144(%rip), %xmm2
    mulsd %xmm0, %xmm4
    addsd ysincos_tab+192(%rip), %xmm4
    mulsd %xmm0, %xmm2
    addsd ysincos_tab+136(%rip), %xmm2
    mulsd %xmm0, %xmm4
    addsd ysincos_tab+184(%rip), %xmm4
    mulsd %xmm0, %xmm2
    addsd ysincos_tab+128(%rip), %xmm2
    mulsd %xmm0, %xmm4
    addsd ysincos_tab+176(%rip), %xmm4
    mulsd %xmm0, %xmm2
    addsd ysincos_tab+120(%rip), %xmm2
    mulsd %xmm0, %xmm4
    addsd ysincos_tab+168(%rip), %xmm4
    mulsd %xmm0, %xmm2
    addsd ysincos_tab+112(%rip), %xmm2
    mulsd %xmm0, %xmm4
    addsd ysincos_tab+160(%rip), %xmm4
# P
    addsd %xmm4, %xmm2                 
    movsd %xmm0, %xmm5
# w*P
    mulsd %xmm2, %xmm5                 
# 1 + w*P
    addsd ysincos_tab+64(%rip), %xmm5           
# times r
    mulsd %xmm3, %xmm5                 
# s
    movsd %xmm5, %xmm6                 
# cos's P, high
    movsd ysincos_tab+264(%rip), %xmm2        
# cos's P, low
    movsd ysincos_tab+328(%rip), %xmm4       
    mulsd %xmm1, %xmm2
    addsd ysincos_tab+256(%rip), %xmm2
    mulsd %xmm1, %xmm4
    addsd ysincos_tab+320(%rip), %xmm4
    mulsd %xmm1, %xmm2
    addsd ysincos_tab+248(%rip), %xmm2
    mulsd %xmm1, %xmm4
    addsd ysincos_tab+312(%rip), %xmm4
    mulsd %xmm1, %xmm2
    addsd ysincos_tab+240(%rip), %xmm2
    mulsd %xmm1, %xmm4
    addsd ysincos_tab+304(%rip), %xmm4
    mulsd %xmm1, %xmm2
    addsd ysincos_tab+232(%rip), %xmm2
    mulsd %xmm1, %xmm4
    addsd ysincos_tab+296(%rip), %xmm4
    mulsd %xmm1, %xmm2
    addsd ysincos_tab+224(%rip), %xmm2
    mulsd %xmm1, %xmm4
    addsd ysincos_tab+288(%rip), %xmm4
    mulsd %xmm1, %xmm2
    addsd ysincos_tab+216(%rip), %xmm2
    mulsd %xmm1, %xmm4
    addsd ysincos_tab+280(%rip), %xmm4
    mulsd %xmm1, %xmm2
    addsd ysincos_tab+208(%rip), %xmm2
    mulsd %xmm1, %xmm4
    addsd ysincos_tab+272(%rip), %xmm4
# P
    addsd %xmm4, %xmm2                 
# w*P
    mulsd %xmm1, %xmm2                 
    movsd ysincos_tab+64(%rip), %xmm7
    subsd %xmm2, %xmm7
# c
    movsd %xmm7, %xmm7                 
# The selection. cos's table is sin's rotated left by one -- sin answers
# [s, c, -s, -c] and cos [c, -s, -c, s] -- so the index is (q + which) & 3, and
# `n & 3` is the Y's quadrant(n) for every n including the negative ones (its
# `n % 4` then `+4` is the low two bits read as unsigned). Then the answer is s
# where the index is even, c where it is odd, and negated where bit 1 is set:
# two tests rather than eight cases.
    mov %r10, %rax
    add %r11, %rax
    and $3, %rax
    test $1, %rax
    jnz ysincos_pick_c
# s into the answer's place
    movsd %xmm6, %xmm7                 
    jmp ysincos_sign
ysincos_pick_c:
    movsd %xmm7, %xmm6
ysincos_sign:
    test $2, %rax
    jz ysincos_done
# The negation is `0.0 - answer` from a zero register, the way the Y writes
# it, and not a sign-bit flip: 0.0 - 0.0 is +0.0, which is what the Y's
# `0.0 - sc[0]` gives, and the difference shows in sin(-0.0).
    movsd ysincos_tab+80(%rip), %xmm5
    subsd %xmm6, %xmm5
    movsd %xmm5, %xmm6
ysincos_done:
    movq %xmm6, %rax
    ret
ysincos_nan:
# The module's `nan` is `0.0 / 0.0`, so the NaN is COMPUTED rather than stored:
# the default NaN carries the sign bit (0xFFF8000000000000), so the one you
# would write from memory is a different double from the one the Y returns.
    movsd ysincos_tab+80(%rip), %xmm0
    divsd %xmm0, %xmm0
    movq %xmm0, %rax
    ret

# ysincos_prod_err(a, b, p) -> the error of a*b given the rounded product p.
# prod_err splits each factor into a head and a tail by multiplying by
# 134217729 = 2^27+1 and subtracting, which leaves the head exact and the tail
# as what is left; then ah*bh - p is the whole error and the three cross terms
# are what a plain product would have thrown away. a in xmm0, b in xmm1, p in
# xmm8, the answer in xmm0. No GPR is touched, so n in %r10 and the choice in
# %r11 survive the call.
ysincos_prod_err:
    movsd ysincos_tab+88(%rip), %xmm2
# a -> ah in xmm7, al in xmm5. Four values are live at once here (ah, al,
# bh, bl), so the four registers are fixed and said out loud: ah xmm7, al
# xmm5, bh xmm6, bl xmm4, and %xmm3 is the scratch the sums go through.
# ah got its own register because the b split wanted the one it was in:
# sharing it computed (bh*bl - p) + bh*bl + al*bh + al*bl, which is not an
# error term at all -- with a = 0 it returned bh*bl where the Y returns 0,
# and every argument below pi/4 came out with 4.39e-8 added to it (the
# reduction's r = x - err, and err was that much).
    movsd %xmm2, %xmm3
# ca = 2^27+1 times a
    mulsd %xmm0, %xmm3                  
    movsd %xmm3, %xmm4
# ca - a
    subsd %xmm0, %xmm4                 
    movsd %xmm3, %xmm7
# ah = ca - (ca - a)
    subsd %xmm4, %xmm7                 
    movsd %xmm0, %xmm5
# al = a - ah
    subsd %xmm7, %xmm5                 
# b -> bh in xmm6, bl in xmm4
    movsd %xmm2, %xmm3
# cb = 2^27+1 times b
    mulsd %xmm1, %xmm3                  
    movsd %xmm3, %xmm4
# cb - b
    subsd %xmm1, %xmm4                 
    movsd %xmm3, %xmm6
# bh = cb - (cb - b)
    subsd %xmm4, %xmm6                 
    movsd %xmm1, %xmm4
# bl = b - bh
    subsd %xmm6, %xmm4                 
# ((ah*bh - p) + ah*bl + al*bh) + al*bl, in that order
    movsd %xmm7, %xmm0
# ah*bh
    mulsd %xmm6, %xmm0                  
# - p
    subsd %xmm8, %xmm0                 
    movsd %xmm7, %xmm3
# ah*bl
    mulsd %xmm4, %xmm3                  
    addsd %xmm3, %xmm0
    movsd %xmm5, %xmm3
# al*bh
    mulsd %xmm6, %xmm3                  
    addsd %xmm3, %xmm0
    movsd %xmm5, %xmm3
# al*bl
    mulsd %xmm4, %xmm3                  
    addsd %xmm3, %xmm0
    ret


# ysincos_tab: the trigonometry's constants and both split kernels, one label for the lot (a label per entry costs the shaker ~2K instructions of fixpoint each, on every compile). Read as ysincos_tab+N(%rip), N = 8*index.
ysincos_tab:
# two_over_pi
    .quad 4603909380684499075
# pio2_1
    .quad 4609753056924401664
# pio2_1t
    .quad 4454258360616903473
# pio2_2
    .quad 4211270387834552320
# pio2_2t
    .quad 4116416798063671330
# pi_over_4
    .quad 4605249457297304856
# neg_pi_over_4
    .quad -4618122579557470952
# half
    .quad 4602678819172646912
# one
    .quad 4607182418800017408
# two
    .quad 4611686018427387904
# zero
    .quad 0
# 2p27_plus_1
    .quad 4728779608772575232
# pinf
    .quad 9218868437227405312
# ninf
    .quad -4503599627370496
# sk0
    .quad -4628199217061079723
# sk1
    .quad 4575957461383580594
# sk2
    .quad -4671919876302423378
# sk3
    .quad 4523617213548634368
# sk4
    .quad -4730215567969263006
# sk5
    .quad 4460218059470869585
# skl0
    .quad 4353229458807897176
# skl1
    .quad 4333282796600828761
# skl2
    .quad -4917570398781457958
# skl3
    .quad 4279244104747201612
# skl4
    .quad -4987381935462220669
# skl5
    .quad 4216195954515327047
# ck0
    .quad 4602678819172646912
# ck1
    .quad -4637206416315820715
# ck2
    .quad 4564047942368979988
# ck3
    .quad -4685430675182873187
# ck4
    .quad 4508805057795844998
# ck5
    .quad -4746249917250114045
# ck6
    .quad 4443145442696615818
# ck7
    .quad -4815842649164929801
# ckl0
    .quad -4945514458082636888
# ckl1
    .quad -4880454276296132197
# ckl2
    .quad -4900297990214052934
# ckl3
    .quad -4940302662667281953
# ckl4
    .quad 4240917714494940301
# ckl5
    .quad -4988654131465315374
# ckl6
    .quad -5023752350701909927
# ckl7
    .quad -5063459948312864427

# ── the power ───────────────────────────────────────────────────────────────
# y_pow: pow(x, y). Generated by `ytest math-gen pow` from src/y/std/math.y's
# pow_y -- do not retype the table (see that file's note). The sequence is the
# Y's line for line, which is what makes the answers the same doubles rather
# than near ones.
#
# Two arguments, pushed in source order, so the LAST is the one at 8(%rsp) and
# the base is at 16(%rsp). Worth writing down because the other way round is
# the natural reading and is wrong: `sum_asm(a.ptr, len(a))` is the same shape,
# and y_sum reads its pointer -- the FIRST argument -- from 16(%rsp) while its
# count, the last, is at 8(%rsp).
#
# This is the first routine in math.s that CALLS, and that is what the rest of
# its shape follows from. The calls would put their return addresses on top of
# the arguments, so it has a frame; %rcx (x's bits) does not survive a call
# either, and neither does any xmm register, so y is read once into the frame
# and reloaded after each call, and log2_dd below answers a PAIR in two
# registers where the Y leaves it in the module-level cells log2_hi, log2_lo,
# ts_lo and z_lo. x is needed only before the first call, so it stays in %rcx.
#
# Answer's bits in %rax.
y_pow:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
# x's bits, the first argument
    mov 24(%rbp), %rcx                     
# y's bits, the last
    mov 16(%rbp), %rax                      
# y, below the frame
    mov %rax, -8(%rbp)                     
# xmm1 = x
    movq %rcx, %xmm1                       
# xmm2 = y
    movq %rax, %xmm2                       
# if (y == 0.0) return 1.0 -- +0.0 and -0.0 both compare equal to zero,
# which is what the Y's `y == 0.0` does
#
# TWO branches and not one: an UNORDERED comparison sets ZF as well as PF, so a
# bare `je` after this is true for a NaN exponent, and pow(2, nan) came back
# 1.0. The Y's order is what saves it -- `y == 0.0` is false for a NaN, so its
# own NaN arm is what answers -- and the fix is to skip this arm when the
# comparison was unordered rather than to move the NaN test up, which would
# change pow(nan, 0.0) from 1.0 to nan.
    movsd ypow_tab+16(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jp ypow_not_zero
    je ypow_ret_one
ypow_not_zero:
# if (x != x || y != y) return nan. The self-comparison is the NaN test: PF is
# set only for an unordered result, which is the only way a double equals
# something that is not itself.
    ucomisd %xmm1, %xmm1
    jp ypow_ret_nan
    ucomisd %xmm2, %xmm2
    jp ypow_ret_nan
# if (x == 1.0 || x == -1.0): 1.0, or -1.0 when the exponent's parity says so
    movsd ypow_tab+0(%rip), %xmm0
    ucomisd %xmm0, %xmm1
    je ypow_ret_one
    movsd ypow_tab+8(%rip), %xmm0
    ucomisd %xmm0, %xmm1
    jne ypow_not_pm1
# (-1)^anything is +-1, and (-1)^0.5 is 1 -- which is the case a
# "negative base, fractional exponent" rule gets wrong
# is_int(y): y == trunc(y)
    ucomisd %xmm2, %xmm2
    jp ypow_tunch_pm1_i
    movsd ypow_tab+80(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jae ypow_tunch_pm1_i
    movsd ypow_tab+88(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jb ypow_tunch_pm1_i
    cvttsd2si %xmm2, %rax
    cvtsi2sd %rax, %xmm0
    jmp ypow_tdone_pm1_i
ypow_tunch_pm1_i:
    movsd %xmm2, %xmm0
ypow_tdone_pm1_i:
    ucomisd %xmm0, %xmm2
    sete %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_even_pm1
# the parity: trunc(y / 2.0) * 2.0 != y. The halved value goes in %xmm3
# and NOT in %xmm2, which is y itself: dividing y in place leaves the
# comparison below answering against y/2 rather than against y, and every
# exponent with a low bit then reads as an odd one.
    movsd %xmm2, %xmm3
    divsd ypow_tab+32(%rip), %xmm3
    ucomisd %xmm3, %xmm3
    jp ypow_tunch_pm1_p
    movsd ypow_tab+80(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jae ypow_tunch_pm1_p
    movsd ypow_tab+88(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jb ypow_tunch_pm1_p
    cvttsd2si %xmm3, %rax
    cvtsi2sd %rax, %xmm15
    jmp ypow_tdone_pm1_p
ypow_tunch_pm1_p:
    movsd %xmm3, %xmm15
ypow_tdone_pm1_p:
    mulsd ypow_tab+32(%rip), %xmm15
    ucomisd %xmm2, %xmm15
    setne %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_even_pm1
    jmp ypow_odd_pm1
ypow_odd_pm1:
    mov $1, %rax
    jmp ypow_odd_pm1_done
ypow_even_pm1:
    xor %eax, %eax
ypow_odd_pm1_done:
    test %rax, %rax
    jz ypow_ret_one
    jmp ypow_ret_neg_one
ypow_not_pm1:
# if (y == 1.0) return x
    movsd ypow_tab+0(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    je ypow_ret_x
# if (x == 0.0): (+-0)^positive is +-0 -- the sign follows the exponent's
# parity -- and (+-0)^negative is +inf
    movsd ypow_tab+16(%rip), %xmm0
    ucomisd %xmm0, %xmm1
    jne ypow_x_nonzero
# y against zero again
    ucomisd %xmm0, %xmm2                    
    jb ypow_ret_inf
# is_int(y): y == trunc(y)
    ucomisd %xmm2, %xmm2
    jp ypow_tunch_x0_i
    movsd ypow_tab+80(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jae ypow_tunch_x0_i
    movsd ypow_tab+88(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jb ypow_tunch_x0_i
    cvttsd2si %xmm2, %rax
    cvtsi2sd %rax, %xmm0
    jmp ypow_tdone_x0_i
ypow_tunch_x0_i:
    movsd %xmm2, %xmm0
ypow_tdone_x0_i:
    ucomisd %xmm0, %xmm2
    sete %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_even_x0
# the parity: trunc(y / 2.0) * 2.0 != y. The halved value goes in %xmm3
# and NOT in %xmm2, which is y itself: dividing y in place leaves the
# comparison below answering against y/2 rather than against y, and every
# exponent with a low bit then reads as an odd one.
    movsd %xmm2, %xmm3
    divsd ypow_tab+32(%rip), %xmm3
    ucomisd %xmm3, %xmm3
    jp ypow_tunch_x0_p
    movsd ypow_tab+80(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jae ypow_tunch_x0_p
    movsd ypow_tab+88(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jb ypow_tunch_x0_p
    cvttsd2si %xmm3, %rax
    cvtsi2sd %rax, %xmm15
    jmp ypow_tdone_x0_p
ypow_tunch_x0_p:
    movsd %xmm3, %xmm15
ypow_tdone_x0_p:
    mulsd ypow_tab+32(%rip), %xmm15
    ucomisd %xmm2, %xmm15
    setne %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_even_x0
    jmp ypow_odd_x0
ypow_odd_x0:
    mov $1, %rax
    jmp ypow_odd_x0_done
ypow_even_x0:
    xor %eax, %eax
ypow_odd_x0_done:
    test %rax, %rax
    jnz ypow_ret_neg_zero
    jmp ypow_ret_zero
ypow_x_nonzero:
# if (is_inf(x)): the parity sign belongs to the BASE being negative, so a
# positive infinity to any power is positive and pow(inf, 3) is +inf. x is not
# a NaN by now, so is_inf is these two comparisons -- the Y's is
# `!is_nan(x) && !is_finite(x)` and the first half is an earlier test above.
    movsd ypow_tab+40(%rip), %xmm0
    ucomisd %xmm0, %xmm1
    je ypow_x_isinf
    movsd ypow_tab+48(%rip), %xmm0
    ucomisd %xmm0, %xmm1
    jne ypow_not_inf
ypow_x_isinf:
    ucomisd ypow_tab+16(%rip), %xmm2
# y < 0 -> +0.0
    jb ypow_ret_zero                       
    ucomisd ypow_tab+16(%rip), %xmm1
# a positive base -> +inf
    jae ypow_ret_inf                       
# is_int(y): y == trunc(y)
    ucomisd %xmm2, %xmm2
    jp ypow_tunch_inf_i
    movsd ypow_tab+80(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jae ypow_tunch_inf_i
    movsd ypow_tab+88(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jb ypow_tunch_inf_i
    cvttsd2si %xmm2, %rax
    cvtsi2sd %rax, %xmm0
    jmp ypow_tdone_inf_i
ypow_tunch_inf_i:
    movsd %xmm2, %xmm0
ypow_tdone_inf_i:
    ucomisd %xmm0, %xmm2
    sete %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_even_inf
# the parity: trunc(y / 2.0) * 2.0 != y. The halved value goes in %xmm3
# and NOT in %xmm2, which is y itself: dividing y in place leaves the
# comparison below answering against y/2 rather than against y, and every
# exponent with a low bit then reads as an odd one.
    movsd %xmm2, %xmm3
    divsd ypow_tab+32(%rip), %xmm3
    ucomisd %xmm3, %xmm3
    jp ypow_tunch_inf_p
    movsd ypow_tab+80(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jae ypow_tunch_inf_p
    movsd ypow_tab+88(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jb ypow_tunch_inf_p
    cvttsd2si %xmm3, %rax
    cvtsi2sd %rax, %xmm15
    jmp ypow_tdone_inf_p
ypow_tunch_inf_p:
    movsd %xmm3, %xmm15
ypow_tdone_inf_p:
    mulsd ypow_tab+32(%rip), %xmm15
    ucomisd %xmm2, %xmm15
    setne %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_even_inf
    jmp ypow_odd_inf
ypow_odd_inf:
    mov $1, %rax
    jmp ypow_odd_inf_done
ypow_even_inf:
    xor %eax, %eax
ypow_odd_inf_done:
    test %rax, %rax
    jz ypow_ret_inf
    jmp ypow_ret_neg_inf
ypow_not_inf:
# else if (x < 0.0): a negative base needs an integer exponent, and past 1024
# there are too many squarings to do -- the logarithm carries it instead, with
# the sign back on afterwards
    movsd ypow_tab+16(%rip), %xmm0
    ucomisd %xmm0, %xmm1
    jae ypow_x_positive
# is_int(y): y == trunc(y)
    ucomisd %xmm2, %xmm2
    jp ypow_tunch_neg
    movsd ypow_tab+80(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jae ypow_tunch_neg
    movsd ypow_tab+88(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jb ypow_tunch_neg
    cvttsd2si %xmm2, %rax
    cvtsi2sd %rax, %xmm0
    jmp ypow_tdone_neg
ypow_tunch_neg:
    movsd %xmm2, %xmm0
ypow_tdone_neg:
    ucomisd %xmm0, %xmm2
    sete %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_ret_nan
# -1024 <= y <= 1024, as the Y writes it: y >= -1024.0 && y <= 1024.0
    movsd ypow_tab+56(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    ja ypow_neg_big
    movsd ypow_tab+8(%rip), %xmm0
    mulsd ypow_tab+56(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jb ypow_neg_big
    cvttsd2si %xmm2, %rax
    movq %xmm1, %xmm0
    mov %rax, %rdi
    call ypow_int
    jmp ypow_ret
ypow_neg_big:
# the sign goes on afterwards, so it is decided BEFORE the call (the call
# takes it) and remembered in the frame
# the parity: trunc(y / 2.0) * 2.0 != y. The halved value goes in %xmm3
# and NOT in %xmm2, which is y itself: dividing y in place leaves the
# comparison below answering against y/2 rather than against y, and every
# exponent with a low bit then reads as an odd one.
    movsd %xmm2, %xmm3
    divsd ypow_tab+32(%rip), %xmm3
    ucomisd %xmm3, %xmm3
    jp ypow_tunch_negb
    movsd ypow_tab+80(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jae ypow_tunch_negb
    movsd ypow_tab+88(%rip), %xmm15
    ucomisd %xmm15, %xmm3
    jb ypow_tunch_negb
    cvttsd2si %xmm3, %rax
    cvtsi2sd %rax, %xmm15
    jmp ypow_tdone_negb
ypow_tunch_negb:
    movsd %xmm3, %xmm15
ypow_tdone_negb:
    mulsd ypow_tab+32(%rip), %xmm15
    ucomisd %xmm2, %xmm15
    setne %al
    movzbq %al, %rax
    mov %rax, -16(%rbp)
    movsd ypow_tab+16(%rip), %xmm0
# -x
    subsd %xmm1, %xmm0                     
    movq %xmm0, %xmm1
    call ypow_pos_go
    cmp $0, -16(%rbp)
    je ypow_ret
# `0.0 - v`, which for a finite v is the sign flip and for an infinity
# the answer with the sign the parity asked for. The zero goes in %xmm1,
# not %xmm0: subtracting %xmm0 from itself is 0.0 - 0.0, which is +0.0
# always, and an odd exponent past 1024 then answered +inf where the Y
# answers -inf.
    movsd ypow_tab+16(%rip), %xmm1
    subsd %xmm0, %xmm1
    movsd %xmm1, %xmm0
    jmp ypow_ret
ypow_x_positive:
# else if (is_int(y) && y >= -1024.0 && y <= 1024.0) -> pow_int(x, to_int(y))
# is_int(y): y == trunc(y)
    ucomisd %xmm2, %xmm2
    jp ypow_tunch_posi
    movsd ypow_tab+80(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jae ypow_tunch_posi
    movsd ypow_tab+88(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jb ypow_tunch_posi
    cvttsd2si %xmm2, %rax
    cvtsi2sd %rax, %xmm0
    jmp ypow_tdone_posi
ypow_tunch_posi:
    movsd %xmm2, %xmm0
ypow_tdone_posi:
    ucomisd %xmm0, %xmm2
    sete %al
    movzbq %al, %rax
    test %rax, %rax
    jz ypow_pos
    movsd ypow_tab+56(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    ja ypow_pos
    movsd ypow_tab+8(%rip), %xmm0
    mulsd ypow_tab+56(%rip), %xmm0
    ucomisd %xmm0, %xmm2
    jb ypow_pos
    cvttsd2si %xmm2, %rax
    movq %xmm1, %xmm0
    mov %rax, %rdi
    call ypow_int
    jmp ypow_ret
# pow_pos(x, y), the general path. A separate routine so that the negative
# base above can call it and then apply a sign; it shares y_pow's frame,
# which is why it reloads y from -8(%rbp) rather than taking an argument.
ypow_pos:
    call ypow_pos_go
    jmp ypow_ret
# pow_pos: the logarithm in two parts, the exponent in two parts, and the
# reduced argument in two parts. pow is the one function here that cannot take
# its log's answer at face value, because it multiplies it by the exponent,
# and an exponent of 500 turns the log's half-ulp into 5e-14 of the answer.
# x in %xmm1, y in the frame; the answer in %xmm0.
ypow_pos_go:
    movq %xmm1, %xmm0
# -> %xmm0 l_hi, %xmm1 l_lo
    call ypow_log2_dd                       
    movsd %xmm0, %xmm9
    movsd %xmm1, %xmm10
# u = y * inv_ln2, in two parts: the rounded constant is 1.4e-17 off, and
# that is 7e-15 of an exponent of 500 -- 60 ulps of the answer, for nothing
# more than rounding a constant
    mov -8(%rbp), %rax
    movq %rax, %xmm11
    mulsd ypow_tab+120(%rip), %xmm11
# p = u * l_hi
    movsd %xmm11, %xmm12
    mulsd %xmm9, %xmm12
# q = prod_err(u, l, p) + u * l_lo + l * (prod_err(y, inv_ln2, u) + y *
# inv_ln2_lo), summed left to right as the Y sums it
    movsd %xmm11, %xmm0
    movsd %xmm9, %xmm1
    movsd %xmm12, %xmm8
    movsd ypow_tab+136(%rip), %xmm2
    mulsd %xmm0, %xmm2
    movsd %xmm2, %xmm3
    subsd %xmm0, %xmm3
    movsd %xmm2, %xmm4
    subsd %xmm3, %xmm4
    movsd %xmm0, %xmm5
    subsd %xmm4, %xmm5
    movsd ypow_tab+136(%rip), %xmm2
    mulsd %xmm1, %xmm2
    movsd %xmm2, %xmm3
    subsd %xmm1, %xmm3
    movsd %xmm2, %xmm6
    subsd %xmm3, %xmm6
    movsd %xmm1, %xmm7
    subsd %xmm6, %xmm7
    movsd %xmm4, %xmm0
    mulsd %xmm6, %xmm0
    subsd %xmm8, %xmm0
    movsd %xmm4, %xmm2
    mulsd %xmm7, %xmm2
    addsd %xmm2, %xmm0
    movsd %xmm5, %xmm2
    mulsd %xmm6, %xmm2
    addsd %xmm2, %xmm0
    movsd %xmm5, %xmm2
    mulsd %xmm7, %xmm2
    addsd %xmm2, %xmm0
    movsd %xmm0, %xmm13
    movsd %xmm11, %xmm0
    mulsd %xmm10, %xmm0
    movsd %xmm0, %xmm14
    addsd %xmm14, %xmm13
    mov -8(%rbp), %rax
    movq %rax, %xmm0
    movsd ypow_tab+120(%rip), %xmm1
    movsd %xmm11, %xmm8
    movsd ypow_tab+136(%rip), %xmm2
    mulsd %xmm0, %xmm2
    movsd %xmm2, %xmm3
    subsd %xmm0, %xmm3
    movsd %xmm2, %xmm4
    subsd %xmm3, %xmm4
    movsd %xmm0, %xmm5
    subsd %xmm4, %xmm5
    movsd ypow_tab+136(%rip), %xmm2
    mulsd %xmm1, %xmm2
    movsd %xmm2, %xmm3
    subsd %xmm1, %xmm3
    movsd %xmm2, %xmm6
    subsd %xmm3, %xmm6
    movsd %xmm1, %xmm7
    subsd %xmm6, %xmm7
    movsd %xmm4, %xmm0
    mulsd %xmm6, %xmm0
    subsd %xmm8, %xmm0
    movsd %xmm4, %xmm2
    mulsd %xmm7, %xmm2
    addsd %xmm2, %xmm0
    movsd %xmm5, %xmm2
    mulsd %xmm6, %xmm2
    addsd %xmm2, %xmm0
    movsd %xmm5, %xmm2
    mulsd %xmm7, %xmm2
    addsd %xmm2, %xmm0
    mov -8(%rbp), %rax
    movq %rax, %xmm1
    mulsd ypow_tab+128(%rip), %xmm1
    addsd %xmm1, %xmm0
    movsd %xmm0, %xmm15
    mulsd %xmm15, %xmm9
    addsd %xmm9, %xmm13
    movsd %xmm12, %xmm0
    movsd %xmm13, %xmm1
    call ypow_exp2_corr
    ret
ypow_ret:
# a float answer's bits go in %rax
    movq %xmm0, %rax                       
    mov %rbp, %rsp
    pop %rbp
    ret
ypow_ret_one:
    movsd ypow_tab+0(%rip), %xmm0
    jmp ypow_ret
ypow_ret_neg_one:
    movsd ypow_tab+8(%rip), %xmm0
    jmp ypow_ret
ypow_ret_zero:
    movsd ypow_tab+16(%rip), %xmm0
    jmp ypow_ret
ypow_ret_neg_zero:
    movsd ypow_tab+16(%rip), %xmm0
    mulsd ypow_tab+8(%rip), %xmm0
    jmp ypow_ret
ypow_ret_x:
    movq %xmm1, %xmm0
    jmp ypow_ret
ypow_ret_inf:
    movsd ypow_tab+40(%rip), %xmm0
    jmp ypow_ret
ypow_ret_neg_inf:
    movsd ypow_tab+48(%rip), %xmm0
    jmp ypow_ret
ypow_ret_nan:
# The module's `nan` is `0.0 / 0.0`, so the NaN is COMPUTED rather than stored:
# the default NaN carries the sign bit (0xFFF8000000000000), so the one you
# would write from memory is a different double from the one the Y returns.
    movsd ypow_tab+16(%rip), %xmm0
    divsd %xmm0, %xmm0
    jmp ypow_ret


# ypow_int(x, n): repeated squaring over the BITS of the exponent. b is
# x^(2^i) at step i and is multiplied in when bit i is set, so an integer
# exponent comes out of as many rounded multiplies as the Y does -- which is
# what the bit-identity promise is: the same sequence of roundings, not a
# better one. x in %xmm0, n in %rdi, the answer in %xmm0.
ypow_int:
# k = |n|, and whether to reciprocate at the end. The flag is a REGISTER
# rather than the sign of the negated %rdi, because that is what the first
# version did and it reciprocated every positive exponent: `neg %rdi` leaves
# the opposite sign behind, so the test at the end read it backwards.
# not negative
    mov $0, %r10                           
# kk
    mov %rdi, %rsi                         
    test %rdi, %rdi
    jns ypow_int_go
# negative: k = 0 - n
    mov $1, %r10                           
    neg %rsi
ypow_int_go:
# r = 1.0
    movsd ypow_tab+0(%rip), %xmm1                        
ypow_int_loop:
# kk % 2 == 1
    test $1, %rsi                           
    jz ypow_int_sqr
# r = r * b
    mulsd %xmm0, %xmm1                      
ypow_int_sqr:
# b = b * b
    mulsd %xmm0, %xmm0                      
# kk = kk / 2
    shr $1, %rsi                            
    jnz ypow_int_loop
    test %r10, %r10
    jz ypow_int_ret
    movsd ypow_tab+0(%rip), %xmm0
# 1.0 / r
    divsd %xmm1, %xmm0                      
    ret
ypow_int_ret:
    movsd %xmm1, %xmm0
    ret

# ypow_log2_dd(x): log(x) in two parts, the second left in %xmm1 instead of
# in the module-level cell the Y calls log2_lo. The reduction is y_log's, line
# for line -- frexp with its subnormal guard, the inv_sqrt2 step, log_z's
# division and its quotient error -- because it is the same arithmetic; only
# the last four lines differ, and they differ because pow multiplies this
# answer by an exponent. x in %xmm0, the pair in %xmm0 and %xmm1.
ypow_log2_dd:
    movq %xmm0, %xmm2
# if (x != x || x < 0.0): nan, and the low part 0.0. `jb` is the x < 0 test:
# x is not a NaN by then, so CF=1 means below zero and nothing else.
    ucomisd %xmm2, %xmm2
    jp ypow_l2_nan
    movsd ypow_tab+16(%rip), %xmm8
    ucomisd %xmm8, %xmm2
    jb ypow_l2_nan
# if (x == 0.0) return -inf, low part 0.0
    ucomisd %xmm8, %xmm2
    je ypow_l2_ninf
# if (is_inf(x)) return inf, low part 0.0. x >= 0 here, so +inf or nothing.
    movsd %xmm2, %xmm0
    ucomisd ypow_tab+40(%rip), %xmm0
    je ypow_l2_pinf
# frexp. The mantissa is this mantissa at exponent 1022, in BITS because there
# is no float-to-long conversion; the sign comes off and goes back on as the
# exponent's sign, which x being positive here has already settled.
# r = x
    movq %xmm2, %xmm5                       
    movq %xmm5, %rax
    shr $52, %rax
    and $2047, %rax
# the guard counter
    xor %ecx, %ecx                          
    test %rax, %rax
    jnz ypow_l2_norm_done
# A subnormal has no implicit leading bit, so it is doubled until its field is
# not 0. The Y's loop also tests `r != 0.0`; x is not zero here (that case
# returned above) and doubling a nonzero never reaches zero.
ypow_l2_norm:
    cmp $60, %rcx
    jge ypow_l2_norm_done
    movq %xmm5, %rax
    shr $52, %rax
    and $2047, %rax
    test %rax, %rax
    jnz ypow_l2_norm_done
    movsd %xmm5, %xmm8
# r = r * 2.0
    mulsd ypow_tab+32(%rip), %xmm8                        
    movsd %xmm8, %xmm5
    add $1, %rcx
    jmp ypow_l2_norm
ypow_l2_norm_done:
    movq %xmm5, %rax
    mov %rax, %rdx
    shr $52, %rdx
# the exponent field
    and $2047, %rdx                         
    mov $4503599627370495, %r10
    and %r10, %rax
    mov $4602678819172646912, %r10
# at exponent 1022, so [0.5, 1)
    or %r10, %rax                           
# m
    movq %rax, %xmm2                        
    sub $1022, %rdx
# e = field - 1022 - guard
    sub %rcx, %rdx                          
# if (m < inv_sqrt2) { m = m * 2.0; e = e - 1 }, which keeps |z| at
# sqrt(2) - 1 rather than reaching 1
    movsd ylog_tab+0(%rip), %xmm8
    ucomisd %xmm8, %xmm2
    jae ypow_l2_m_ok
    movsd %xmm2, %xmm8
    mulsd ypow_tab+32(%rip), %xmm8
    movsd %xmm8, %xmm2
    sub $1, %rdx
ypow_l2_m_ok:
# ef = (float) e
    cvtsi2sd %rdx, %xmm6                    
# log_z(m): num = m - 1; den = m + 1; bb = den - m; derr = (m - (den - bb)) +
# (1 - bb); z = num / den; z_lo = -(z * derr) / den. m + 1 rounds and its
# half-ulp is a whole ulp of z, which is what the second divide puts back.
    movsd %xmm2, %xmm0
# num
    subsd ypow_tab+0(%rip), %xmm0                        
    movsd %xmm2, %xmm1
# den
    addsd ypow_tab+0(%rip), %xmm1                        
    movsd %xmm1, %xmm8
# bb = den - m
    subsd %xmm2, %xmm8                      
    movsd %xmm1, %xmm3
# den - bb
    subsd %xmm8, %xmm3                      
    movsd %xmm2, %xmm4
# m - (den - bb)
    subsd %xmm3, %xmm4                      
    movsd ypow_tab+0(%rip), %xmm3
# 1 - bb
    subsd %xmm8, %xmm3                      
# derr
    addsd %xmm3, %xmm4                      
# z = num / den
    divsd %xmm1, %xmm0                      
    movsd %xmm0, %xmm7
# z * derr
    mulsd %xmm4, %xmm7                      
    movsd ypow_tab+16(%rip), %xmm8
# -(z * derr)
    subsd %xmm7, %xmm8                      
# z_lo
    divsd %xmm1, %xmm8                      
# z = z + z_lo
    addsd %xmm8, %xmm0                      
    movsd %xmm0, %xmm3
# w = z * z
    mulsd %xmm0, %xmm3                      
# a = two_sum(2.0 * z, (z * w) * P), NOT z * (2.0 + w * P) -- the Y's
# change, and the reason pow was three ulps out at some arguments. The
# brackets in the other form round at the size of 2.0, which is a whole ulp
# of the logarithm, and pow multiplies the logarithm by the exponent. The
# scaling by two here is exact and (z*w)*P is two orders smaller, so the
# two_sum carries what the brackets used to drop.
    movsd ylog_tab+144(%rip), %xmm2
    movsd ylog_tab+232(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+136(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+224(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+128(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+216(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+120(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+208(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+112(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+200(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+104(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+192(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+96(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+184(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+88(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+176(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+80(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+168(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+72(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+160(%rip), %xmm9
    mulsd %xmm3, %xmm2
    addsd ylog_tab+64(%rip), %xmm2
    mulsd %xmm3, %xmm9
    addsd ylog_tab+152(%rip), %xmm9
    addsd %xmm9, %xmm2
    movsd %xmm0, %xmm4
# a = 2.0 * z, and exact: it is a
    mulsd ypow_tab+32(%rip), %xmm4                        
# scaling by a power of two
                                             
# b = (z * w) * P
    movsd %xmm3, %xmm7                       
    mulsd %xmm0, %xmm7
    mulsd %xmm2, %xmm7
# two_sum(a, b) in the Y's order: bb = s - a, and the residual is
  
# (a - (s - bb)) + (b - bb) -- it lands in %xmm5 and rides into the pair
  
    movsd %xmm4, %xmm5
# s
    addsd %xmm7, %xmm4                       
    movsd %xmm4, %xmm8
# bb = s - a
    subsd %xmm5, %xmm8                      
    movsd %xmm4, %xmm10
# s - bb
    subsd %xmm8, %xmm10                     
# a - (s - bb)
    subsd %xmm10, %xmm5                     
    movsd %xmm7, %xmm11
# b - bb
    subsd %xmm8, %xmm11                     
    addsd %xmm11, %xmm5
# b = two_sum(ef * ln2_hi, ef * ln2_lo), and bc_lo what that summation lost.
# The two terms are of very different sizes -- this one is e * ln 2 and the
# small one is the kernel's -- and the rounding that matters is this one's, so
# this is the one two_sum keeps track of.
    movsd %xmm6, %xmm7
# ef * ln2_hi
    mulsd ylog_tab+8(%rip), %xmm7                        
    movsd %xmm6, %xmm8
# ef * ln2_lo
    mulsd ylog_tab+16(%rip), %xmm8                        
    movsd %xmm7, %xmm9
# s = p + q
    addsd %xmm8, %xmm9                      
    movsd %xmm9, %xmm10
# bb = s - p
    subsd %xmm7, %xmm10                     
    movsd %xmm9, %xmm11
# s - bb
    subsd %xmm10, %xmm11                    
# p - (s - bb)
    subsd %xmm11, %xmm7                     
    movsd %xmm8, %xmm12
# q - bb
    subsd %xmm10, %xmm12                    
# bc_lo
    addsd %xmm12, %xmm7                     
# t = two_sum(a, b), and the answer's low part is what this lost plus bc_lo
# `a` is %xmm4 -- it was %xmm0 until the two_sum above moved it, and this
# block reading the wrong register is how the first version of that change
# answered 86 cases of the table three orders of magnitude out
    movsd %xmm4, %xmm13
# t = a + b
    addsd %xmm9, %xmm13                     
    movsd %xmm13, %xmm14
# bb2 = t - a
    subsd %xmm4, %xmm14                     
    movsd %xmm13, %xmm15
# t - bb2
    subsd %xmm14, %xmm15                    
# a - (t - bb2)
    subsd %xmm15, %xmm4                     
    movsd %xmm9, %xmm12
# b - bb2
    subsd %xmm14, %xmm12                    
# The residual lands in %xmm4 and NOT %xmm0: `a` moved there when the
  
# two_sum above was introduced, and the Y puts the residual in the `a`
  
# variable. %xmm0 still holds z, and the version that summed into it
  
# returned lo = z -- a log2_dd pair whose low half was a quarter of the
  
# log, which is what put 85 of the table's pow cases over three ulps.
  
    addsd %xmm12, %xmm4
# lo = (what t lost + what a lost) + bc_lo, the Y's order and not the
  
# other one: these three are of one size and their sum is not associative
  
# ts_lo + a_lo
    addsd %xmm5, %xmm4                      
# + bc_lo
    addsd %xmm7, %xmm4                      
    movsd %xmm4, %xmm1
# hi = t
    movsd %xmm13, %xmm0                     
    ret
ypow_l2_nan:
    movsd ypow_tab+16(%rip), %xmm0
# 0.0 / 0.0 is the module's nan
    divsd %xmm0, %xmm0                      
# the low part is 0.0
    movsd ypow_tab+16(%rip), %xmm1                        
    ret
ypow_l2_pinf:
    movsd ypow_tab+40(%rip), %xmm0
    movsd ypow_tab+16(%rip), %xmm1
    ret
ypow_l2_ninf:
    movsd ypow_tab+48(%rip), %xmm0
    movsd ypow_tab+16(%rip), %xmm1
    ret

# ypow_exp2_corr(p, q): 2^(p + q), where q is what the exponent's own rounding
# left over. It has to be added AFTER the reduction -- an exponent error is an
# absolute error in the reduced argument, and before the reduction it would be
# multiplied by the whole exponent -- and it has to SURVIVE the reduction too,
# which is the part that is easy to miss: one ulp of an exponent of 500 is
# 5.7e-14 of the answer, 360 ulps of it. p in %xmm0, q in %xmm1, the answer in
# %xmm0. The frame is because ldexp is called and every xmm register is
# caller-saved: hi, lo and k all have to be in memory across those calls.
ypow_exp2_corr:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
# if (p != p) return p
    ucomisd %xmm0, %xmm0
    jp ypow_e2_nan
    movsd ypow_tab+56(%rip), %xmm8
    ucomisd %xmm8, %xmm0
    ja ypow_e2_inf
    movsd ypow_tab+72(%rip), %xmm8
    ucomisd %xmm8, %xmm0
    jb ypow_e2_zero
# n = floor(p + 0.5): truncation, and one less when it rounded UP -- which is
# when the truncated value is GREATER than the value it came from
    movsd %xmm0, %xmm2
    addsd ypow_tab+24(%rip), %xmm2
    cvttsd2si %xmm2, %rax
    cvtsi2sd %rax, %xmm3
    ucomisd %xmm2, %xmm3
    jbe ypow_e2_n_ok
    sub $1, %rax
ypow_e2_n_ok:
# n as a float
    cvtsi2sd %rax, %xmm4                     
# s = (p - n) + q, in that order: the exponent's remainder, then what the
# exponent itself lost
    movsd %xmm0, %xmm5
    subsd %xmm4, %xmm5
# s
    addsd %xmm1, %xmm5                      
# t = s * ln2
    movsd %xmm5, %xmm6
# t
    mulsd ypow_tab+112(%rip), %xmm6                        
# k = to_int(n)
    mov %rax, %rdi                          
# f2 = 1.0, and 2.0 with one off k when n is past the largest exponent
    movsd ypow_tab+0(%rip), %xmm7
    movsd ypow_tab+64(%rip), %xmm8
    ucomisd %xmm8, %xmm4
    jbe ypow_e2_f2_ok
    sub $1, %rdi
    movsd ypow_tab+32(%rip), %xmm7
ypow_e2_f2_ok:
# hi = f2 * (1.0 + t * (1.0 + t * poly_split(exp_k, exp_kl, t))). The multiply
# by f2 is LAST, as in the Y, and the polynomial is yexp_tab's -- the same
# coefficients the same generator read for y_exp, read here rather than
# copied, because the same coefficients in two tables is a table that can
# disagree with itself.
    movsd yexp_tab+176(%rip), %xmm2
    movsd yexp_tab+280(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+168(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+272(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+160(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+264(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+152(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+256(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+144(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+248(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+136(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+240(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+128(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+232(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+120(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+224(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+112(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+216(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+104(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+208(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+96(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+200(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+88(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+192(%rip), %xmm9
    mulsd %xmm6, %xmm2
    addsd yexp_tab+80(%rip), %xmm2
    mulsd %xmm6, %xmm9
    addsd yexp_tab+184(%rip), %xmm9
    addsd %xmm9, %xmm2
    movsd %xmm6, %xmm3
# t * P
    mulsd %xmm2, %xmm3                      
    addsd ypow_tab+0(%rip), %xmm3
# t * (1 + t*P)
    mulsd %xmm6, %xmm3                      
    addsd ypow_tab+0(%rip), %xmm3
# * f2
    mulsd %xmm7, %xmm3                      
# hi
    movsd %xmm3, %xmm9                      
# lo = hi * prod_err(s, ln2, t): e^(t + t_lo) = e^t * e^t_lo = e^t + e^t *
# t_lo for a t_lo of 1e-17
    movsd %xmm5, %xmm0
# b = ln2
    movsd ypow_tab+112(%rip), %xmm1                        
# p = t
    movsd %xmm6, %xmm8                      
    movsd ypow_tab+136(%rip), %xmm2
    mulsd %xmm0, %xmm2
    movsd %xmm2, %xmm3
    subsd %xmm0, %xmm3
    movsd %xmm2, %xmm4
    subsd %xmm3, %xmm4
    movsd %xmm0, %xmm5
    subsd %xmm4, %xmm5
    movsd ypow_tab+136(%rip), %xmm2
    mulsd %xmm1, %xmm2
    movsd %xmm2, %xmm3
    subsd %xmm1, %xmm3
    movsd %xmm2, %xmm6
    subsd %xmm3, %xmm6
    movsd %xmm1, %xmm7
    subsd %xmm6, %xmm7
    movsd %xmm4, %xmm0
    mulsd %xmm6, %xmm0
    subsd %xmm8, %xmm0
    movsd %xmm4, %xmm2
    mulsd %xmm7, %xmm2
    addsd %xmm2, %xmm0
    movsd %xmm5, %xmm2
    mulsd %xmm6, %xmm2
    addsd %xmm2, %xmm0
    movsd %xmm5, %xmm2
    mulsd %xmm7, %xmm2
    addsd %xmm2, %xmm0
# lo = hi * the error
    mulsd %xmm9, %xmm0                      
# ldexp(hi, k) + ldexp(lo, k), and the three values go to the frame first
    movsd %xmm9, -8(%rbp)
    movsd %xmm0, -16(%rbp)
    mov %rdi, -24(%rbp)
    movsd -8(%rbp), %xmm0
    mov -24(%rbp), %rdi
    call ypow_ldexp
    movsd %xmm0, -8(%rbp)
    movsd -16(%rbp), %xmm0
    mov -24(%rbp), %rdi
    call ypow_ldexp
    addsd -8(%rbp), %xmm0
    mov %rbp, %rsp
    pop %rbp
    ret
ypow_e2_nan:
    mov %rbp, %rsp
    pop %rbp
    ret
ypow_e2_inf:
    movsd ypow_tab+40(%rip), %xmm0
    mov %rbp, %rsp
    pop %rbp
    ret
ypow_e2_zero:
    movsd ypow_tab+16(%rip), %xmm0
    mov %rbp, %rsp
    pop %rbp
    ret

# ypow_ldexp(x, e): x scaled by 2^e. The big steps first, since after them the
# answer may already be 0 or an infinity and there is nothing left to do
# exactly; 2^1022 rather than 2^1023, so that one step never overflows on its
# own. Then, if the answer is still NORMAL, the exponent field is the whole of
# the job -- k * 2^52 added to the bits IS k added to the field -- and the sign
# comes off first and goes back on after, because a negative pattern would put
# a 1 at the top of an 11-bit field and scale the wrong way. Otherwise one
# doubling or halving at a time, which is how that is exact (and is also the
# subnormal case: a subnormal's field is 0, so every step of it is a
# doubling). x in %xmm0, e in %rdi, the answer in %xmm0.
ypow_ldexp:
# r = x
    movq %xmm0, %xmm3                       
# k = e
    mov %rdi, %rsi                          
# if (x != x || x == 0.0 || is_inf(x)) return x -- all four answer themselves
    ucomisd %xmm3, %xmm3
    jp ypow_ld_ret
    movsd ypow_tab+16(%rip), %xmm8
    ucomisd %xmm8, %xmm3
    je ypow_ld_ret
    ucomisd ypow_tab+40(%rip), %xmm3
    je ypow_ld_ret
    ucomisd ypow_tab+48(%rip), %xmm3
    je ypow_ld_ret
    cmp $1022, %rsi
    jl ypow_ld_big_done
ypow_ld_big:
    mulsd ypow_tab+96(%rip), %xmm3
    sub $1022, %rsi
    cmp $1022, %rsi
    jge ypow_ld_big
ypow_ld_big_done:
    cmp $-1022, %rsi
    jg ypow_ld_small_done
ypow_ld_small:
    mulsd ypow_tab+104(%rip), %xmm3
    add $1022, %rsi
    cmp $-1022, %rsi
    jle ypow_ld_small
ypow_ld_small_done:
    movq %xmm3, %rax
    shr $52, %rax
    mov $2047, %rdx
# f = the exponent field
    and %rdx, %rax                          
    test %rax, %rax
    jz ypow_ld_double
    mov %rax, %rdx
# f + k
    add %rsi, %rdx                          
    cmp $1, %rdx
    jl ypow_ld_double
    test %rsi, %rsi
# k == 0
    jz ypow_ld_ret                          
# b = r's bits
    movq %xmm3, %rax                        
    test %rax, %rax
    js ypow_ld_neg
    mov $4503599627370496, %rdx
    imul %rsi, %rdx
    add %rdx, %rax
    movq %rax, %xmm3
    jmp ypow_ld_ret
ypow_ld_neg:
    mov $-9223372036854775808, %rdx
# without_sign(b)
    add %rdx, %rax                          
    mov $4503599627370496, %rdx
    imul %rsi, %rdx
    add %rdx, %rax
    mov $-9223372036854775808, %rdx
# the sign goes back on
    add %rdx, %rax                          
    movq %rax, %xmm3
    jmp ypow_ld_ret
ypow_ld_double:
# step = k < 0 ? -1 : 1
    mov $1, %rdx                            
    test %rsi, %rsi
    jns ypow_ld_step_ok
    mov $-1, %rdx
ypow_ld_step_ok:
# rest = k
    mov %rsi, %rcx                          
    test %rcx, %rcx
    jz ypow_ld_ret
ypow_ld_dbl:
    cmp $-1, %rdx
    jne ypow_ld_dbl_up
# r = r * 0.5
    mulsd ypow_tab+24(%rip), %xmm3                        
    jmp ypow_ld_dbl_next
ypow_ld_dbl_up:
# r = r * 2.0
    mulsd ypow_tab+32(%rip), %xmm3                        
ypow_ld_dbl_next:
    sub %rdx, %rcx
    test %rcx, %rcx
    jnz ypow_ld_dbl
ypow_ld_ret:
    movsd %xmm3, %xmm0
    ret


# ypow_tab: pow's own constants, one label for the lot (a label per entry costs the shaker ~2K instructions of fixpoint each, on every compile). Read as ypow_tab+N(%rip), N = 8*index. The logarithm's kernel and the exponent's are NOT here: they are ylog_tab's and yexp_tab's, read where they already are, because the same coefficients in two tables is a table that can disagree with itself.
ypow_tab:
# one
    .quad 4607182418800017408
# neg_one
    .quad -4616189618054758400
# zero
    .quad 0
# half
    .quad 4602678819172646912
# two
    .quad 4611686018427387904
# pinf
    .quad 9218868437227405312
# ninf
    .quad -4503599627370496
# p1024
    .quad 4652218415073722368
# p1023
    .quad 4652209618980700160
# neg_1075
    .quad -4570929321408987136
# two63
    .quad 4890909195324358656
# neg_two63
    .quad -4332462841530417152
# big_step
    .quad 9209861237972664320
# small_step
    .quad 4503599627370496
# ln2
    .quad 4604418534313441775
# inv_ln2
    .quad 4609176140021203710
# inv_ln2_lo
    .quad 4357082904033627428
# prod_split
    .quad 4728779608772575232

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
