# wcon.s -- the console on Windows, behind the Linux terminal calls tui.y makes.
#
# A termios is what the module reads and writes (tui.y manipulates c_lflag, VMIN
# and VTIME in a 64-byte buffer); the console has one DWORD of mode instead.
# y_os_ioctl translates, keeping the real mode in c_cflag so that restoring a
# saved termios restores the exact console mode:
#   TCGETS   c_cflag = the console mode; c_lflag's ISIG / ICANON / ECHO from
#            ENABLE_PROCESSED_INPUT / ENABLE_LINE_INPUT / ENABLE_ECHO_INPUT;
#            VMIN 1, VTIME 0; ENOTTY (-25) for a handle that is no console
#   TCSETS   those three bits from c_lflag; with ICANON off the console is put
#            in virtual-terminal input mode (ENABLE_VIRTUAL_TERMINAL_INPUT 0x200:
#            the arrow keys then arrive as the escape sequences tui.y decodes),
#            quick-edit off; the screen side is switched to virtual-terminal
#            output (0x4) so the module's escape sequences are interpreted
#   TIOCGWINSZ  the window of the screen buffer, rows and columns
#   anything else (TIOCSWINSZ included)  ENOTTY
# VMIN and VTIME are kept for y_os_tty_read, which honours "no key within VTIME
# tenths of a second" by waiting on the console input handle.
#
# API cells: 35 GetConsoleMode 36 SetConsoleMode 37 GetConsoleScreenBufferInfo
# (8 WaitForSingleObject is wproc.s's).

#=== replace: y_os_ioctl ===
y_os_ioctl:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $160, %rsp
    and $-16, %rsp
    mov 32(%rbp), %rdi
    call y_os_handle
    mov %rax, %rbx
    mov 24(%rbp), %r12
    mov 16(%rbp), %r13
    cmp $21505, %r12
    je yoi_get
    cmp $21506, %r12
    je yoi_set
    cmp $21507, %r12
    je yoi_set
    cmp $21508, %r12
    je yoi_set
    cmp $21523, %r12
    je yoi_win
yoi_notty:
    mov $-25, %rax
    jmp yoi_out
yoi_get:
    lea yw_apis(%rip), %rcx
    add $280, %rcx
    lea ywn_y_os_ioctl_GetConsoleMode(%rip), %r8
    call y_w_api_k32
    xor %ecx, %ecx
    mov %rcx, 64(%rsp)
    mov %rbx, %rcx
    lea 64(%rsp), %rdx
    call *%rax
    test %eax, %eax
    jz yoi_notty
    xor %ecx, %ecx
    mov %rcx, 0(%r13)
    mov %rcx, 8(%r13)
    mov %rcx, 16(%r13)
    mov %rcx, 24(%r13)
    mov %rcx, 32(%r13)
    mov $21474837760, %rax
    mov %rax, 0(%r13)
    mov 64(%rsp), %rax
    shl $32, %rax
    shr $32, %rax
    mov $32816, %rdx
    mov %rax, %rcx
    and $1, %rcx
    jz yoi_g1
    or $1, %rdx
yoi_g1:
    mov %rax, %rcx
    and $2, %rcx
    jz yoi_g2
    or $2, %rdx
yoi_g2:
    mov %rax, %rcx
    and $4, %rcx
    jz yoi_g3
    or $8, %rdx
yoi_g3:
    shl $32, %rdx
    or %rdx, %rax
    mov %rax, 8(%r13)
    mov $72057594037927936, %rax
    mov %rax, 16(%r13)
    xor %eax, %eax
    jmp yoi_out
yoi_set:
    mov 8(%r13), %rax
    mov %rax, %rdx
    shr $32, %rdx
    shl $32, %rax
    shr $32, %rax
    and $-8, %rax
    mov %rdx, %rcx
    and $1, %rcx
    jz yoi_s1
    or $1, %rax
yoi_s1:
    mov %rdx, %rcx
    and $8, %rcx
    jz yoi_s2
    or $4, %rax
yoi_s2:
    mov %rdx, %rcx
    and $2, %rcx
    jz yoi_raw
    or $2, %rax
    and $-513, %rax
    jmp yoi_apply
yoi_raw:
    or $640, %rax
    and $-65, %rax
yoi_apply:
    mov %rax, 80(%rsp)
    movzbq 23(%r13), %rax
    mov %rax, yw_vmin(%rip)
    movzbq 22(%r13), %rax
    mov %rax, yw_vtime(%rip)
    lea yw_apis(%rip), %rcx
    add $288, %rcx
    lea ywn_y_os_ioctl_SetConsoleMode(%rip), %r8
    call y_w_api_k32
    mov %rbx, %rcx
    mov 80(%rsp), %rdx
    call *%rax
    test %eax, %eax
    jz yoi_notty
    mov 32(%rbp), %rax
    cmp $0, %rax
    jne yoi_ok
    mov $1, %rdi
    call y_os_handle
    mov %rax, %rbx
    lea yw_apis(%rip), %rcx
    add $280, %rcx
    lea ywn_y_os_ioctl_GetConsoleMode(%rip), %r8
    call y_w_api_k32
    xor %ecx, %ecx
    mov %rcx, 64(%rsp)
    mov %rbx, %rcx
    lea 64(%rsp), %rdx
    call *%rax
    test %eax, %eax
    jz yoi_ok
    lea yw_apis(%rip), %rcx
    add $288, %rcx
    lea ywn_y_os_ioctl_SetConsoleMode(%rip), %r8
    call y_w_api_k32
    mov %rbx, %rcx
    mov 64(%rsp), %rdx
    or $5, %rdx
    call *%rax
yoi_ok:
    xor %eax, %eax
    jmp yoi_out
yoi_win:
    lea yw_apis(%rip), %rcx
    add $296, %rcx
    lea ywn_y_os_ioctl_GetConsoleScreenBufferInfo(%rip), %r8
    call y_w_api_k32
    mov %rbx, %rcx
    lea 96(%rsp), %rdx
    call *%rax
    test %eax, %eax
    jz yoi_notty
    movzbq 106(%rsp), %rax
    movzbq 107(%rsp), %rcx
    shl $8, %rcx
    or %rcx, %rax
    movzbq 110(%rsp), %rdx
    movzbq 111(%rsp), %rcx
    shl $8, %rcx
    or %rcx, %rdx
    sub %rax, %rdx
    add $1, %rdx
    movzbq 108(%rsp), %rax
    movzbq 109(%rsp), %rcx
    shl $8, %rcx
    or %rcx, %rax
    movzbq 112(%rsp), %r8
    movzbq 113(%rsp), %rcx
    shl $8, %rcx
    or %rcx, %r8
    sub %rax, %r8
    add $1, %r8
    shl $16, %rdx
    or %rdx, %r8
    mov %r8, 0(%r13)
    xor %eax, %eax
yoi_out:
    lea -24(%rbp), %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywn_y_os_ioctl_GetConsoleMode: .string "GetConsoleMode"
ywn_y_os_ioctl_SetConsoleMode: .string "SetConsoleMode"
ywn_y_os_ioctl_GetConsoleScreenBufferInfo: .string "GetConsoleScreenBufferInfo"

#=== replace: y_os_tty_read ===
y_os_tty_read:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $96, %rsp
    and $-16, %rsp
    mov yw_vtime(%rip), %rax
    test %rax, %rax
    jz yotr_plain
    mov yw_vmin(%rip), %rax
    test %rax, %rax
    jnz yotr_plain
    xor %edi, %edi
    call y_os_handle
    mov %rax, %rbx
    lea yw_apis(%rip), %rcx
    add $280, %rcx
    lea ywn_y_os_tty_read_GetConsoleMode(%rip), %r8
    call y_w_api_k32
    xor %ecx, %ecx
    mov %rcx, 64(%rsp)
    mov %rbx, %rcx
    lea 64(%rsp), %rdx
    call *%rax
    test %eax, %eax
    jz yotr_plain
    lea yw_apis(%rip), %rcx
    add $64, %rcx
    lea ywn_y_os_tty_read_WaitForSingleObject(%rip), %r8
    call y_w_api_k32
    mov %rbx, %rcx
    mov yw_vtime(%rip), %rdx
    mov $100, %r8
    imul %r8, %rdx
    call y_w_cb
    cmp $258, %eax
    jne yotr_plain
    xor %eax, %eax
    jmp yotr_out
yotr_plain:
    xor %eax, %eax
    push %rax
    mov 24(%rbp), %rax
    push %rax
    mov 16(%rbp), %rax
    push %rax
    call y_os_read
    add $24, %rsp
yotr_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_tty_read_GetConsoleMode: .string "GetConsoleMode"
ywn_y_os_tty_read_WaitForSingleObject: .string "WaitForSingleObject"

#=== replace: y_os_setsid ===
y_os_setsid:
    mov $-38, %rax
    ret
# waveOut audio (winmm.dll), behind snd.y's Windows path. The device is opened for
# 16-bit PCM at the stream's rate and channel count; a write hands the whole buffer
# to the driver as ONE block and returns when the driver is done with it, so a
# write is "played" when it returns (and snd.drain has nothing left to wait for).
# API cells: 40 waveOutGetNumDevs 41 waveOutOpen 42 waveOutPrepareHeader
# 43 waveOutWrite 44 waveOutUnprepareHeader 45 waveOutClose 46 waveOutReset.
#=== add: y_w_api_winmm ===
y_w_api_winmm:
    lea ywd_winmm(%rip), %rdx
    jmp y_w_api
ywd_winmm: .string "winmm.dll"

# y_os_audio_devs() -> the number of output devices.
#=== replace: y_os_audio_devs ===
y_os_audio_devs:
    push %rbp
    mov %rsp, %rbp
    sub $48, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $320, %rcx
    lea ywn_y_os_audio_devs_waveOutGetNumDevs(%rip), %r8
    call y_w_api_winmm
    call *%rax
    shl $32, %rax
    shr $32, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_audio_devs_waveOutGetNumDevs: .string "waveOutGetNumDevs"

# y_os_audio_open(rate, channels) -> a device handle, or -1: waveOutOpen on the
# default output for 16-bit PCM.
#=== replace: y_os_audio_open ===
y_os_audio_open:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    sub $112, %rsp
    and $-16, %rsp
    mov 24(%rbp), %r12
    mov 16(%rbp), %rbx
    mov %rbx, %rax
    shl $16, %rax
    or $1, %rax
    mov %r12, %rcx
    shl $32, %rcx
    or %rcx, %rax
    mov %rax, 64(%rsp)
    mov %rbx, %rcx
    add %rcx, %rcx
    mov %rcx, %rdx
    imul %r12, %rdx
    mov %rcx, %rax
    shl $32, %rax
    or %rdx, %rax
    mov $16, %rdx
    shl $48, %rdx
    or %rdx, %rax
    mov %rax, 72(%rsp)
    xor %eax, %eax
    mov %rax, 80(%rsp)
    lea yw_apis(%rip), %rcx
    add $328, %rcx
    lea ywn_y_os_audio_open_waveOutOpen(%rip), %r8
    call y_w_api_winmm
    lea 56(%rsp), %rcx
    mov $-1, %rdx
    lea 64(%rsp), %r8
    xor %r9d, %r9d
    xor %r10d, %r10d
    mov %r10, 32(%rsp)
    mov %r10, 40(%rsp)
    call *%rax
    test %eax, %eax
    jnz yoao_fail
    mov 56(%rsp), %rax
    jmp yoao_out
yoao_fail:
    mov $-1, %rax
yoao_out:
    lea -16(%rbp), %rsp
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywn_y_os_audio_open_waveOutOpen: .string "waveOutOpen"

# y_os_audio_write(h, buf, len) -> len once the driver has played it, or -1.
# A WAVEHDR is 48 bytes: lpData, dwBufferLength, dwBytesRecorded, dwUser,
# dwFlags (at +24: WHDR_DONE is bit 0), dwLoops, lpNext, reserved.
#=== replace: y_os_audio_write ===
y_os_audio_write:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $160, %rsp
    and $-16, %rsp
    mov 32(%rbp), %r12
    lea 80(%rsp), %rbx
    xor %eax, %eax
    mov %rax, 0(%rbx)
    mov %rax, 8(%rbx)
    mov %rax, 16(%rbx)
    mov %rax, 24(%rbx)
    mov %rax, 32(%rbx)
    mov %rax, 40(%rbx)
    mov 24(%rbp), %rax
    mov %rax, 0(%rbx)
    mov 16(%rbp), %rax
    mov %rax, 8(%rbx)
    lea yw_apis(%rip), %rcx
    add $336, %rcx
    lea ywn_y_os_audio_write_waveOutPrepareHeader(%rip), %r8
    call y_w_api_winmm
    mov %r12, %rcx
    mov %rbx, %rdx
    mov $48, %r8
    call *%rax
    test %eax, %eax
    jnz yoaw_fail
    lea yw_apis(%rip), %rcx
    add $344, %rcx
    lea ywn_y_os_audio_write_waveOutWrite(%rip), %r8
    call y_w_api_winmm
    mov %r12, %rcx
    mov %rbx, %rdx
    mov $48, %r8
    call *%rax
    test %eax, %eax
    jnz yoaw_unprep
yoaw_wait:
    mov 24(%rbx), %rax
    and $1, %rax
    jnz yoaw_done
    call y_w_block_begin
    call y_w_pause
    call y_w_block_end
    jmp yoaw_wait
yoaw_done:
    xor %r13d, %r13d
    jmp yoaw_finish
yoaw_unprep:
    mov $-1, %r13
yoaw_finish:
    lea yw_apis(%rip), %rcx
    add $352, %rcx
    lea ywn_y_os_audio_write_waveOutUnprepareHeader(%rip), %r8
    call y_w_api_winmm
    mov %r12, %rcx
    mov %rbx, %rdx
    mov $48, %r8
    call *%rax
    test %r13, %r13
    jnz yoaw_fail
    mov 16(%rbp), %rax
    jmp yoaw_out
yoaw_fail:
    mov $-1, %rax
yoaw_out:
    lea -24(%rbp), %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywn_y_os_audio_write_waveOutPrepareHeader: .string "waveOutPrepareHeader"
ywn_y_os_audio_write_waveOutWrite: .string "waveOutWrite"
ywn_y_os_audio_write_waveOutUnprepareHeader: .string "waveOutUnprepareHeader"

# y_os_audio_close(h) -> 0: waveOutReset, waveOutClose.
#=== replace: y_os_audio_close ===
y_os_audio_close:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $48, %rsp
    and $-16, %rsp
    mov 16(%rbp), %rbx
    lea yw_apis(%rip), %rcx
    add $368, %rcx
    lea ywn_y_os_audio_close_waveOutReset(%rip), %r8
    call y_w_api_winmm
    mov %rbx, %rcx
    call *%rax
    lea yw_apis(%rip), %rcx
    add $360, %rcx
    lea ywn_y_os_audio_close_waveOutClose(%rip), %r8
    call y_w_api_winmm
    mov %rbx, %rcx
    call *%rax
    xor %eax, %eax
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_audio_close_waveOutReset: .string "waveOutReset"
ywn_y_os_audio_close_waveOutClose: .string "waveOutClose"
