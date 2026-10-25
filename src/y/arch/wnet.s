# wnet.s -- sockets on Windows: Winsock (ws2_32), resolved on first use, behind
# the Linux-shaped socket calls the std modules make (net.y, ipc.y). A socket
# handle is the descriptor; reads, writes and closes of one go through recv, send
# and closesocket (y_os_recv, y_os_send, y_os_closesocket), because the file
# calls ignore SO_RCVTIMEO and a blocking call here must be one the collector can
# see (y_w_cb).  A failed call answers the NEGATIVE Linux errno of the Winsock
# error (y_w_wsaerr), so the callers' `-98` (address in use) and `-111`
# (connection refused) mean the same on both targets.  Linux layouts are the
# contract: sockaddr_in / sockaddr_un are the same bytes in Winsock, a socket
# option's level and name are translated (SOL_SOCKET 1 -> 0xffff, SO_RCVTIMEO's
# timeval -> milliseconds), and poll takes the Linux 8-byte pollfd.
#
# API cache cells: 14 WSAStartup 15 WSAGetLastError 16 socket 17 connect 18 bind
# 19 listen 20 accept 21 getsockname 22 setsockopt 23 send 24 recv 25 closesocket
# 26 WSAPoll 27 GetNetworkParams (see wsys.s).

# y_w_api_ws2(cell, name): y_w_api for ws2_32.dll, starting Winsock (WSAStartup
# 2.2) the first time any of it is used.
#=== add: y_w_api_ws2 ===
y_w_api_ws2:
    mov (%rcx), %rax
    test %rax, %rax
    jz yws_slow
    ret
yws_slow:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    sub $480, %rsp
    and $-16, %rsp
    mov %rcx, %rbx
    mov %r8, %r12
    mov yw_wsa(%rip), %rax
    test %rax, %rax
    jnz yws_started
    lea yw_apis(%rip), %rcx
    add $112, %rcx
    lea ywn_ws_WSAStartup(%rip), %r8
    lea ywd_ws2(%rip), %rdx
    call y_w_api
    test %rax, %rax
    jz yws_out
    mov $514, %rcx
    lea 48(%rsp), %rdx
    call *%rax
    test %eax, %eax
    jnz yws_out
    mov $1, %rcx
    mov %rcx, yw_wsa(%rip)
yws_started:
    mov %rbx, %rcx
    lea ywd_ws2(%rip), %rdx
    mov %r12, %r8
    call y_w_api
yws_out:
    lea -16(%rbp), %rsp
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywd_ws2: .string "ws2_32.dll"
ywn_ws_WSAStartup: .string "WSAStartup"
#=== add: y_w_api_iphlp ===
y_w_api_iphlp:
    lea ywd_iphlp(%rip), %rdx
    jmp y_w_api
ywd_iphlp: .string "iphlpapi.dll"

# y_w_cb: call the Win64 function in %rax with the arguments in %rcx %rdx %r8
# %r9, from a thread the collector can pass. Until the program has started a
# thread it is the call itself. After, the thread publishes state 4 ("in a
# system call", with an %rsp below every register it holds, as y_gc_syscall
# does) for the duration of the call, so a cycle does not wait for it; on the way
# out it clears the state with a full fence and parks if a cycle began meanwhile.
#=== add: y_w_cb ===
y_w_cb:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rdi
    push %rsi
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    mov %rax, %r12
    lea y_heap(%rip), %r11
    mov 24(%r11), %r11
    test %r11, %r11
    jnz ywcb_threaded
    sub $32, %rsp
    call *%r12
    jmp ywcb_out
ywcb_threaded:
    mov %rcx, %r13
    mov %rdx, %r14
    mov %r8, %r15
    mov %r9, %rbx
ywcb_check:
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jz ywcb_go
    mov y_gc_safe_fn(%rip), %rax
    call *%rax
    jmp ywcb_check
ywcb_go:
    mov %gs:5752, %rax
    mov %rsp, 88(%rax)
    mov $4, %rcx
    mov %rcx, 96(%rax)
    mov %r13, %rcx
    mov %r14, %rdx
    mov %r15, %r8
    mov %rbx, %r9
    sub $32, %rsp
    call *%r12
    add $32, %rsp
    mov %rax, %r13
    mov %gs:5752, %rcx
    xor %eax, %eax
    xchg %rax, 96(%rcx)
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jz ywcb_back
    mov y_gc_safe_fn(%rip), %rax
    call *%rax
ywcb_back:
    mov %r13, %rax
ywcb_out:
    lea -56(%rbp), %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rsi
    pop %rdi
    pop %rbx
    pop %rbp
    ret

# y_w_wsaerr -> -errno in %rax: the Linux errno of WSAGetLastError()'s answer
# (-5, EIO, for one with no Linux twin).
#=== add: y_w_wsaerr ===
y_w_wsaerr:
    push %rbp
    mov %rsp, %rbp
    sub $48, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $120, %rcx
    lea ywn_wsaerr_WSAGetLastError(%rip), %r8
    call y_w_api_ws2
    call *%rax
    shl $32, %rax
    shr $32, %rax
    cmp $10004, %rax
    je ywe_10004
    cmp $10009, %rax
    je ywe_10009
    cmp $10013, %rax
    je ywe_10013
    cmp $10014, %rax
    je ywe_10014
    cmp $10022, %rax
    je ywe_10022
    cmp $10024, %rax
    je ywe_10024
    cmp $10035, %rax
    je ywe_10035
    cmp $10036, %rax
    je ywe_10036
    cmp $10038, %rax
    je ywe_10038
    cmp $10040, %rax
    je ywe_10040
    cmp $10042, %rax
    je ywe_10042
    cmp $10043, %rax
    je ywe_10043
    cmp $10044, %rax
    je ywe_10044
    cmp $10047, %rax
    je ywe_10047
    cmp $10048, %rax
    je ywe_10048
    cmp $10049, %rax
    je ywe_10049
    cmp $10050, %rax
    je ywe_10050
    cmp $10051, %rax
    je ywe_10051
    cmp $10052, %rax
    je ywe_10052
    cmp $10053, %rax
    je ywe_10053
    cmp $10054, %rax
    je ywe_10054
    cmp $10055, %rax
    je ywe_10055
    cmp $10056, %rax
    je ywe_10056
    cmp $10057, %rax
    je ywe_10057
    cmp $10058, %rax
    je ywe_10058
    cmp $10060, %rax
    je ywe_10060
    cmp $10061, %rax
    je ywe_10061
    cmp $10064, %rax
    je ywe_10064
    cmp $10065, %rax
    je ywe_10065
    mov $-5, %rax
ywe_done:
    mov %rbp, %rsp
    pop %rbp
    ret
ywe_10004:
    mov $-4, %rax
    jmp ywe_done
ywe_10009:
    mov $-9, %rax
    jmp ywe_done
ywe_10013:
    mov $-13, %rax
    jmp ywe_done
ywe_10014:
    mov $-14, %rax
    jmp ywe_done
ywe_10022:
    mov $-22, %rax
    jmp ywe_done
ywe_10024:
    mov $-24, %rax
    jmp ywe_done
ywe_10035:
    mov $-11, %rax
    jmp ywe_done
ywe_10036:
    mov $-115, %rax
    jmp ywe_done
ywe_10038:
    mov $-9, %rax
    jmp ywe_done
ywe_10040:
    mov $-90, %rax
    jmp ywe_done
ywe_10042:
    mov $-92, %rax
    jmp ywe_done
ywe_10043:
    mov $-93, %rax
    jmp ywe_done
ywe_10044:
    mov $-94, %rax
    jmp ywe_done
ywe_10047:
    mov $-97, %rax
    jmp ywe_done
ywe_10048:
    mov $-98, %rax
    jmp ywe_done
ywe_10049:
    mov $-99, %rax
    jmp ywe_done
ywe_10050:
    mov $-100, %rax
    jmp ywe_done
ywe_10051:
    mov $-101, %rax
    jmp ywe_done
ywe_10052:
    mov $-102, %rax
    jmp ywe_done
ywe_10053:
    mov $-103, %rax
    jmp ywe_done
ywe_10054:
    mov $-104, %rax
    jmp ywe_done
ywe_10055:
    mov $-105, %rax
    jmp ywe_done
ywe_10056:
    mov $-106, %rax
    jmp ywe_done
ywe_10057:
    mov $-107, %rax
    jmp ywe_done
ywe_10058:
    mov $-108, %rax
    jmp ywe_done
ywe_10060:
    mov $-110, %rax
    jmp ywe_done
ywe_10061:
    mov $-111, %rax
    jmp ywe_done
ywe_10064:
    mov $-112, %rax
    jmp ywe_done
ywe_10065:
    mov $-113, %rax
    jmp ywe_done
ywn_wsaerr_WSAGetLastError: .string "WSAGetLastError"

# y_os_socket(domain, type, proto) -> a socket, or -errno. Type bits above the
# low four (SOCK_CLOEXEC) are flags: the handle is made non-inheritable for it.
#=== replace: y_os_socket ===
y_os_socket:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    mov 24(%rbp), %rbx
    lea yw_apis(%rip), %rcx
    add $128, %rcx
    lea ywn_y_os_socket_socket(%rip), %r8
    call y_w_api_ws2
    mov 32(%rbp), %rcx
    mov 24(%rbp), %rdx
    and $15, %rdx
    mov 16(%rbp), %r8
    call *%rax
    cmp $-1, %rax
    je yosk_fail
    mov %rax, -24(%rbp)
    and $524288, %rbx
    jz yosk_done
    mov -24(%rbp), %rcx
    xor %edx, %edx
    call y_w_inherit
yosk_done:
    mov -24(%rbp), %rax
    jmp yosk_out
yosk_fail:
    call y_w_wsaerr
yosk_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_socket_socket: .string "socket"

# y_os_connect(fd, addr, alen) -> 0, or -errno.
#=== replace: y_os_connect ===
y_os_connect:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $136, %rcx
    lea ywn_y_os_connect_connect(%rip), %r8
    call y_w_api_ws2
    mov 32(%rbp), %rcx
    mov 24(%rbp), %rdx
    mov 16(%rbp), %r8
    call y_w_cb
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl ynet_c_fail
    jmp ynet_c_out
ynet_c_fail:
    call y_w_wsaerr
ynet_c_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_connect_connect: .string "connect"

# y_os_bind(fd, addr, alen) -> 0, or -errno.
#=== replace: y_os_bind ===
y_os_bind:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $144, %rcx
    lea ywn_y_os_bind_bind(%rip), %r8
    call y_w_api_ws2
    mov 32(%rbp), %rcx
    mov 24(%rbp), %rdx
    mov 16(%rbp), %r8
    call *%rax
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl ynet_b_fail
    jmp ynet_b_out
ynet_b_fail:
    call y_w_wsaerr
ynet_b_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_bind_bind: .string "bind"

# y_os_listen(fd, backlog) -> 0, or -errno.
#=== replace: y_os_listen ===
y_os_listen:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $152, %rcx
    lea ywn_y_os_listen_listen(%rip), %r8
    call y_w_api_ws2
    mov 24(%rbp), %rcx
    mov 16(%rbp), %rdx
    call *%rax
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl ynet_l_fail
    jmp ynet_l_out
ynet_l_fail:
    call y_w_wsaerr
ynet_l_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_listen_listen: .string "listen"

# y_os_getsockname(fd, addr, lenp) -> 0, or -errno (lenp: an int, as Linux).
#=== replace: y_os_getsockname ===
y_os_getsockname:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $168, %rcx
    lea ywn_y_os_getsockname_getsockname(%rip), %r8
    call y_w_api_ws2
    mov 32(%rbp), %rcx
    mov 24(%rbp), %rdx
    mov 16(%rbp), %r8
    call *%rax
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl ynet_g_fail
    jmp ynet_g_out
ynet_g_fail:
    call y_w_wsaerr
ynet_g_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_getsockname_getsockname: .string "getsockname"

# y_os_closesocket(fd) -> 0, or -errno.
#=== replace: y_os_closesocket ===
y_os_closesocket:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $200, %rcx
    lea ywn_y_os_closesocket_closesocket(%rip), %r8
    call y_w_api_ws2
    mov 16(%rbp), %rcx
    call *%rax
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl ynet_cs_fail
    jmp ynet_cs_out
ynet_cs_fail:
    call y_w_wsaerr
ynet_cs_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_closesocket_closesocket: .string "closesocket"

# y_os_accept(fd) -> the new socket, or -errno.
#=== replace: y_os_accept ===
y_os_accept:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $160, %rcx
    lea ywn_y_os_accept_accept(%rip), %r8
    call y_w_api_ws2
    mov 16(%rbp), %rcx
    xor %edx, %edx
    xor %r8d, %r8d
    call y_w_cb
    cmp $-1, %rax
    je ynet_a_fail
    jmp ynet_a_out
ynet_a_fail:
    call y_w_wsaerr
ynet_a_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_accept_accept: .string "accept"

# y_os_send(fd, buf, len, flags) -> bytes sent, or -errno (flags are not used).
#=== replace: y_os_send ===
y_os_send:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $184, %rcx
    lea ywn_y_os_send_send(%rip), %r8
    call y_w_api_ws2
    mov 40(%rbp), %rcx
    mov 32(%rbp), %rdx
    mov 24(%rbp), %r8
    xor %r9d, %r9d
    call y_w_cb
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl ynet_s_fail
    jmp ynet_s_out
ynet_s_fail:
    call y_w_wsaerr
ynet_s_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_send_send: .string "send"

# y_os_recv(fd, buf, len) -> bytes received (0 at end of stream), or -errno.
#=== replace: y_os_recv ===
y_os_recv:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $80, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $192, %rcx
    lea ywn_y_os_recv_recv(%rip), %r8
    call y_w_api_ws2
    mov 32(%rbp), %rcx
    mov 24(%rbp), %rdx
    mov 16(%rbp), %r8
    xor %r9d, %r9d
    call y_w_cb
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl ynet_r_fail
    jmp ynet_r_out
ynet_r_fail:
    call y_w_wsaerr
ynet_r_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_recv_recv: .string "recv"

# y_os_setsockopt(fd, level, opt, val, len) -> 0, or -errno. SOL_SOCKET is 1 on
# Linux and 0xffff here; the names that differ are translated (REUSEADDR 2 ->
# 4, KEEPALIVE 9 -> 8, SNDBUF 7 -> 0x1001, RCVBUF 8 -> 0x1002), and the two
# timeouts (20 SO_RCVTIMEO, 21 SO_SNDTIMEO) take a timeval on Linux and a
# DWORD of milliseconds here. Level 6 (TCP) is the same.
#=== replace: y_os_setsockopt ===
y_os_setsockopt:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $96, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $176, %rcx
    lea ywn_y_os_setsockopt_setsockopt(%rip), %r8
    call y_w_api_ws2
    mov %rax, %rbx
    mov 40(%rbp), %rax
    cmp $1, %rax
    jne yoso_plain
    mov 32(%rbp), %rax
    cmp $20, %rax
    je yoso_time
    cmp $21, %rax
    je yoso_time
yoso_plain:
    mov 48(%rbp), %rcx
    mov 40(%rbp), %rdx
    mov 32(%rbp), %r8
    mov 24(%rbp), %r9
    mov 16(%rbp), %r10
    mov %r10, 32(%rsp)
    cmp $1, %rdx
    jne yoso_call
    mov $65535, %rdx
    cmp $2, %r8
    jne yoso_n1
    mov $4, %r8
    jmp yoso_call
yoso_n1:
    cmp $9, %r8
    jne yoso_n2
    mov $8, %r8
    jmp yoso_call
yoso_n2:
    cmp $7, %r8
    jne yoso_n3
    mov $4097, %r8
    jmp yoso_call
yoso_n3:
    cmp $8, %r8
    jne yoso_call
    mov $4098, %r8
    jmp yoso_call
yoso_time:
    mov 24(%rbp), %r9
    mov (%r9), %rax
    mov $1000, %rcx
    imul %rcx, %rax
    mov %rax, %r10
    mov 8(%r9), %rax
    xor %edx, %edx
    div %rcx
    add %rax, %r10
    mov %r10, -24(%rbp)
    mov 48(%rbp), %rcx
    mov $65535, %rdx
    mov 32(%rbp), %r8
    cmp $20, %r8
    jne yoso_snd
    mov $4102, %r8
    jmp yoso_tcommon
yoso_snd:
    mov $4101, %r8
yoso_tcommon:
    lea -24(%rbp), %r9
    mov $4, %r10
    mov %r10, 32(%rsp)
yoso_call:
    call *%rbx
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl yoso_fail
    jmp yoso_out
yoso_fail:
    call y_w_wsaerr
yoso_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_setsockopt_setsockopt: .string "setsockopt"

# y_os_poll(fds, nfds, ms) -> the number of entries with events, 0 on timeout, or
# -errno. fds is the Linux array of 8-byte pollfd (int fd, short events, short
# revents), at most 16 of them; each is turned into a WSAPOLLFD (POLLIN -> POLLRDNORM,
# POLLOUT -> POLLWRNORM) and the answers turned back (POLLERR 8, POLLHUP 16, POLLNVAL 32).
#=== replace: y_os_poll ===
y_os_poll:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $400, %rsp
    and $-16, %rsp
    mov 32(%rbp), %r12
    mov 24(%rbp), %r13
    cmp $16, %r13
    jg yopl_inval
    lea 96(%rsp), %rbx
    xor %ecx, %ecx
yopl_build:
    cmp %r13, %rcx
    jge yopl_built
    mov %rcx, %rax
    shl $3, %rax
    add %r12, %rax
    mov (%rax), %rdx
    shl $32, %rdx
    sar $32, %rdx
    movzbq 4(%rax), %r8
    xor %r9d, %r9d
    mov %r8, %r10
    and $1, %r10
    jz yopl_noin
    or $256, %r9
yopl_noin:
    and $4, %r8
    jz yopl_noout
    or $16, %r9
yopl_noout:
    mov %rcx, %rax
    shl $4, %rax
    add %rbx, %rax
    mov %rdx, (%rax)
    mov %r9, 8(%rax)
    add $1, %rcx
    jmp yopl_build
yopl_built:
    lea yw_apis(%rip), %rcx
    add $208, %rcx
    lea ywn_y_os_poll_WSAPoll(%rip), %r8
    call y_w_api_ws2
    mov %rbx, %rcx
    mov %r13, %rdx
    mov 16(%rbp), %r8
    shl $32, %r8
    sar $32, %r8
    call y_w_cb
    shl $32, %rax
    sar $32, %rax
    cmp $0, %rax
    jl yopl_fail
    mov %rax, -40(%rbp)
    xor %ecx, %ecx
yopl_back:
    cmp %r13, %rcx
    jge yopl_done
    mov %rcx, %rax
    shl $4, %rax
    add %rbx, %rax
    movzbq 10(%rax), %r8
    movzbq 11(%rax), %r9
    shl $8, %r9
    or %r9, %r8
    xor %r9d, %r9d
    mov %r8, %r10
    and $768, %r10
    jz yopl_r1
    or $1, %r9
yopl_r1:
    mov %r8, %r10
    and $48, %r10
    jz yopl_r2
    or $4, %r9
yopl_r2:
    mov %r8, %r10
    and $1, %r10
    jz yopl_r3
    or $8, %r9
yopl_r3:
    mov %r8, %r10
    and $2, %r10
    jz yopl_r4
    or $16, %r9
yopl_r4:
    and $4, %r8
    jz yopl_r5
    or $32, %r9
yopl_r5:
    mov %rcx, %rax
    shl $3, %rax
    add %r12, %rax
    mov %r9, %rdx
    movb %dl, 6(%rax)
    shr $8, %rdx
    movb %dl, 7(%rax)
    add $1, %rcx
    jmp yopl_back
yopl_done:
    mov -40(%rbp), %rax
    jmp yopl_out
yopl_inval:
    mov $-22, %rax
    jmp yopl_out
yopl_fail:
    call y_w_wsaerr
yopl_out:
    lea -24(%rbp), %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywn_y_os_poll_WSAPoll: .string "WSAPoll"

# y_os_dns_servers(buf, cap) -> the length of the text written to buf: the
# system's DNS servers (iphlpapi GetNetworkParams) as `nameserver a.b.c.d` lines,
# the format resolv.conf has, which net.y reads either way. 0 if there are none.
#=== replace: y_os_dns_servers ===
y_os_dns_servers:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    sub $2200, %rsp
    and $-16, %rsp
    mov 24(%rbp), %r12
    lea yw_apis(%rip), %rcx
    add $216, %rcx
    lea ywn_y_os_dns_servers_GetNetworkParams(%rip), %r8
    call y_w_api_iphlp
    lea 64(%rsp), %rcx
    lea 48(%rsp), %rdx
    mov $2048, %r8
    mov %r8, (%rdx)
    call *%rax
    test %eax, %eax
    jnz yods_none
    lea 336(%rsp), %rbx
    mov %r12, %r8
    mov 24(%rbp), %r9
    mov 16(%rbp), %rax
    add %rax, %r9
    sub $32, %r9
yods_node:
    cmp %r9, %r8
    jge yods_end
    movzbq 8(%rbx), %rax
    test %rax, %rax
    jz yods_next
    lea ydns_pre(%rip), %rsi
yods_p:
    movzbq (%rsi), %rax
    test %rax, %rax
    jz yods_ip
    movb %al, (%r8)
    add $1, %rsi
    add $1, %r8
    jmp yods_p
yods_ip:
    lea 8(%rbx), %rsi
yods_i:
    movzbq (%rsi), %rax
    test %rax, %rax
    jz yods_nl
    movb %al, (%r8)
    add $1, %rsi
    add $1, %r8
    jmp yods_i
yods_nl:
    movb $10, (%r8)
    add $1, %r8
yods_next:
    mov (%rbx), %rbx
    test %rbx, %rbx
    jnz yods_node
yods_end:
    mov %r8, %rax
    sub %r12, %rax
    jmp yods_out
yods_none:
    xor %eax, %eax
yods_out:
    lea -16(%rbp), %rsp
    pop %r12
    pop %rbx
    pop %rbp
    ret
ydns_pre: .string "nameserver "
ywn_y_os_dns_servers_GetNetworkParams: .string "GetNetworkParams"

# y_os_getuid() -> the user id: Windows has none, so 0.
#=== replace: y_os_getuid ===
y_os_getuid:
    xor %eax, %eax
    ret
