# web.s -- the web target's own blocks.
#
# Only these six differ from Linux: the four audio entries and the two host
# calls go to the host's private syscall numbers (Appendix C) instead of a
# Linux syscall or -ENOSYS. Everything else is the Linux body, which the host
# emulates. This file is GNU as source like every other arch file,
# so make asm-check covers it; the wasm lowering reads the same blocks.
#=== replace: y_os_audio_devs ===
y_os_audio_devs:
    mov $22787, %eax          # Y_WEB_AUDIO_DEVS
    syscall
    ret
#=== replace: y_os_audio_open ===
# (rate, channels): rate at 16(%rsp), channels at 8(%rsp)
y_os_audio_open:
    mov 16(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov $22788, %eax          # Y_WEB_AUDIO_OPEN
    syscall
    ret
#=== replace: y_os_audio_write ===
# (h, buf, len): 24, 16, 8
y_os_audio_write:
    mov 24(%rsp), %rdi
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov $22789, %eax          # Y_WEB_AUDIO_WRITE
    syscall
    ret
#=== replace: y_os_audio_close ===
# (h): 8
y_os_audio_close:
    mov 8(%rsp), %rdi
    mov $22790, %eax          # Y_WEB_AUDIO_CLOSE
    syscall
    ret
#=== replace: y_os_host_sym ===
# (name, len): 16, 8
y_os_host_sym:
    mov 16(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov $22785, %eax          # Y_WEB_HOST_SYM
    syscall
    ret
#=== replace: y_os_host_call ===
# (handle, args, n): 24, 16, 8
y_os_host_call:
    mov 24(%rsp), %rdi
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov $22786, %eax          # Y_WEB_HOST_CALL
    syscall
    ret
