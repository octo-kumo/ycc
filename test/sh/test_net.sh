#!/bin/bash
# Exercise the blocking net listeners over loopback.  The first connection
# is also the readiness probe; the next one makes each handler exit cleanly.
# Then the resolver against a fake DNS server (test/y/net/dns_srv.y), and
# the TLS 1.3 client against openssl s_server (test/y/net/tls_cli.y).
set -u

source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d -t ytest_net.XXXXXX)
PIDS=()
SERVER_PID=""
PORT=""
REQUEST_RESULT=""
START_DETAIL=""

cleanup() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

forget_pid() {
    local target="$1" pid
    local -a remaining=()
    for pid in "${PIDS[@]}"; do
        [ "$pid" = "$target" ] || remaining+=("$pid")
    done
    PIDS=("${remaining[@]}")
}

job_running() {
    local pid
    for pid in $(jobs -pr); do
        [ "$pid" = "$1" ] && return 0
    done
    return 1
}

compile_server_pair() {
    local name="$1" source="$ROOT/test/y/net/$1.y"
    local ref="$WORK/$name.ref" copy="$WORK/$name.copy"
    local timeout_s=$((60 * YTIMEOUT_SCALE))

    if ! compile_ref "$source" "$ref" "$timeout_s"; then
        fail "$name reference compile" "$RUN_RERR"
        return 1
    fi
    if ! compile_copy "$source" "$copy" "$timeout_s"; then
        fail "$name C-copy compile" "$RUN_CERR"
        return 1
    fi
    if ! cmp -s "$ref" "$copy"; then
        fail "$name compiler parity" "compiled server binaries differ"
        return 1
    fi
    pass "$name compiler parity"
    return 0
}

start_server() {
    local binary="$1" port="$2" limit="$3" low_fd="${4:-0}"
    local log="$WORK/$(basename "$binary")-$port.log"
    if [ "$low_fd" -eq 32 ]; then
        (
            ulimit -n 32
            exec timeout --kill-after=1 20 "$binary" "$port" "$limit"
        ) </dev/null >"$log" 2>&1 &
    else
        timeout --kill-after=1 20 "$binary" "$port" "$limit" </dev/null >"$log" 2>&1 &
    fi
    SERVER_PID=$!
    PIDS+=("$SERVER_PID")
}

reap_server() {
    local pid="$SERVER_PID" status
    wait "$pid"
    status=$?
    forget_pid "$pid"
    SERVER_PID=""
    return "$status"
}

stop_server() {
    local pid="$SERVER_PID"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    forget_pid "$pid"
    SERVER_PID=""
}

open_client() {
    local port="$1"
    exec 4>&2
    exec 2>/dev/null
    if exec 3<>"/dev/tcp/127.0.0.1/$port"; then
        exec 2>&4
        exec 4>&-
        return 0
    fi
    exec 2>&4
    exec 4>&-
    return 1
}

http_request() {
    local port="$1" request="$2" got status
    if ! open_client "$port"; then
        return 1
    fi
    if ! printf '%s' "$request" >&3; then
        exec 3>&-
        return 1
    fi
    got=$(timeout 3 cat <&3 2>/dev/null)
    status=$?
    exec 3>&-
    [ "$status" -eq 0 ] || return 1
    REQUEST_RESULT="$got"
    return 0
}

tcp_request() {
    local port="$1" request="${2:-ping}" got status
    if ! open_client "$port"; then
        return 1
    fi
    if ! printf '%s' "$request" >&3; then
        exec 3>&-
        return 1
    fi
    got=$(timeout 3 cat <&3 2>/dev/null)
    status=$?
    exec 3>&-
    [ "$status" -eq 0 ] || return 1
    REQUEST_RESULT="$got"
    return 0
}

http_fire() {
    local port="$1" request="$2"
    if ! open_client "$port"; then
        return 1
    fi
    if ! printf '%s' "$request" >&3; then
        exec 3>&-
        return 1
    fi
    exec 3>&-
    return 0
}

tcp_fire() {
    local port="$1"
    if ! open_client "$port"; then
        return 1
    fi
    exec 3>&-
    return 0
}

random_port() {
    printf '%d\n' $((20000 + (((RANDOM << 15) | RANDOM) % 40001)))
}

start_http() {
    local binary="$1" limit="$2" expected
    local attempt=0 port pid polls ready got
    expected=$'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nhttp-ok'
    START_DETAIL=""
    while [ "$attempt" -lt 20 ]; do
        port="$(random_port)"
        start_server "$binary" "$port" "$limit"
        pid="$SERVER_PID"
        polls=0
        ready=0
        while [ "$polls" -lt 50 ]; do
            if ! job_running "$pid"; then
                break
            fi
            if http_request "$port" $'GET /x HTTP/1.0\r\n\r\n'; then
                got="$REQUEST_RESULT"
                if [ "$got" = "$expected" ]; then
                    if job_running "$pid"; then
                        ready=1
                    fi
                    break
                fi
                if job_running "$pid"; then
                    START_DETAIL="port $port answered with a different response; retrying"
                fi
                break
            fi
            sleep 0.1
            polls=$((polls + 1))
        done
        if [ "$ready" -eq 1 ]; then
            PORT="$port"
            return 0
        fi
        if job_running "$pid"; then
            stop_server
        else
            wait "$pid" 2>/dev/null || true
            forget_pid "$pid"
            SERVER_PID=""
        fi
        attempt=$((attempt + 1))
    done
    [ -n "$START_DETAIL" ] || START_DETAIL="no HTTP listener became ready after 20 port attempts"
    return 1
}

start_tcp() {
    local binary="$1" limit="$2" low_fd="${3:-0}"
    local expected="tcp-ok"
    local attempt=0 port pid polls ready got
    START_DETAIL=""
    while [ "$attempt" -lt 20 ]; do
        port="$(random_port)"
        start_server "$binary" "$port" "$limit" "$low_fd"
        pid="$SERVER_PID"
        polls=0
        ready=0
        while [ "$polls" -lt 50 ]; do
            if ! job_running "$pid"; then
                break
            fi
            if tcp_request "$port"; then
                got="$REQUEST_RESULT"
                if [ "$got" = "$expected" ]; then
                    if job_running "$pid"; then
                        ready=1
                    fi
                    break
                fi
                if job_running "$pid"; then
                    START_DETAIL="port $port answered with a different response; retrying"
                fi
                break
            fi
            sleep 0.1
            polls=$((polls + 1))
        done
        if [ "$ready" -eq 1 ]; then
            PORT="$port"
            return 0
        fi
        if job_running "$pid"; then
            stop_server
        else
            wait "$pid" 2>/dev/null || true
            forget_pid "$pid"
            SERVER_PID=""
        fi
        attempt=$((attempt + 1))
    done
    [ -n "$START_DETAIL" ] || START_DETAIL="no TCP listener became ready after 20 port attempts"
    return 1
}

test_http() {
    local binary="$1" label="$2"
    if ! start_http "$binary" 2; then
        fail "$label listen_http" "$START_DETAIL"
        return
    fi
    if ! http_fire "$PORT" $'GET /stop HTTP/1.0\r\n\r\n'; then
        fail "$label listen_http" "could not send the handler's final request"
        stop_server
        return
    fi
    if reap_server; then
        pass "$label listen_http response and exit"
    else
        fail "$label listen_http" "server did not exit successfully"
    fi
}

test_tcp() {
    local binary="$1" label="$2"
    if ! start_tcp "$binary" 2; then
        fail "$label listen_tcp" "$START_DETAIL"
        return
    fi
    if ! tcp_fire "$PORT"; then
        fail "$label listen_tcp" "could not open the handler's final connection"
        stop_server
        return
    fi
    if reap_server; then
        pass "$label listen_tcp response and exit"
    else
        fail "$label listen_tcp" "server did not exit successfully"
    fi
}

test_tcp_accept_leak() {
    local binary="$1" label="$2" i got ok=1
    if ! start_tcp "$binary" 101 32; then
        fail "$label accept-loop fd limit" "$START_DETAIL"
        return
    fi
    for ((i = 2; i <= 100; i++)); do
        if ! tcp_request "$PORT"; then
            ok=0
            START_DETAIL="connection $i did not receive a complete response"
            break
        fi
        got="$REQUEST_RESULT"
        if [ "$got" != "tcp-ok" ]; then
            ok=0
            START_DETAIL="connection $i returned an unexpected response"
            break
        fi
    done
    if [ "$ok" -eq 1 ] && tcp_fire "$PORT"; then
        if reap_server; then
            pass "$label listen_tcp serves 100 connections under ulimit -n 32"
        else
            fail "$label accept-loop fd limit" "server did not exit successfully"
        fi
    else
        fail "$label accept-loop fd limit" "${START_DETAIL:-could not open final shutdown connection}"
        stop_server
    fi
}

http_ok=0
tcp_ok=0
compile_server_pair srv_http && http_ok=1
compile_server_pair srv_tcp && tcp_ok=1

# The resolver (net.resolve_with) against a fake DNS server on loopback
# (test/y/net/dns_srv.y, UDP and TCP on one port): a CNAME and two A
# records, a truncated answer retried over TCP, NXDOMAIN, a malformed
# answer, an unaskable name; then names that need no server.
DNS_EXPECTED="[10.1.2.3, 10.4.5.6]
[10.7.8.9]
[]
[]
[]
[10.0.0.1] [127.0.0.1]"

test_dns() {
    local server="$1" label="$2" attempt=0 port="" log polls got c
    while [ "$attempt" -lt 20 ]; do
        port="$(random_port)"
        start_server "$server" "$port" 0
        log="$WORK/$(basename "$server")-$port.log"
        polls=0
        while [ "$polls" -lt 50 ] && job_running "$SERVER_PID" && ! grep -q ready "$log" 2>/dev/null; do
            sleep 0.1
            polls=$((polls + 1))
        done
        grep -q ready "$log" 2>/dev/null && break
        stop_server
        port=""
        attempt=$((attempt + 1))
    done
    if [ -z "$port" ]; then
        fail "$label DNS server" "no DNS server became ready after 20 port attempts"
        return
    fi
    for c in "$WORK/dns_cli.copy" "$WORK/dns_cli.ref"; do
        got=$(run_bin 30 "$c" "$port" </dev/null 2>&1)
        if [ "$got" = "$DNS_EXPECTED" ]; then
            pass "$label DNS server: $(basename "$c") resolves"
        else
            fail "$label DNS server: $(basename "$c") resolves" "got: $got"
        fi
    done
    stop_server
}
dns_ok=0
compile_server_pair dns_srv && compile_server_pair dns_cli && dns_ok=1
if [ "$dns_ok" -eq 1 ]; then
    test_dns "$WORK/dns_srv.copy" "C copy"
    test_dns "$WORK/dns_srv.ref" "reference"
fi

# The TLS 1.3 client (std/tls.y) against `openssl s_server -www` when the
# machine has openssl: each suite, an RSA and an ECDSA P-384 certificate
# trusted as the anchor, ALPN, and a host the certificate does not name.
tls_case() {
    local suite="$1" cert="$2" key="$3" host="$4" want="$5" extra="${6:-}"
    local attempt=0 port="" pid polls c got
    while [ "$attempt" -lt 20 ]; do
        port="$(random_port)"
        timeout --kill-after=1 20 openssl s_server -accept "$port" -cert "$cert" -key "$key" \
            -tls1_3 -ciphersuites "$suite" $extra -www -quiet </dev/null >/dev/null 2>&1 &
        SERVER_PID=$!
        PIDS+=("$SERVER_PID")
        polls=0
        while [ "$polls" -lt 50 ] && job_running "$SERVER_PID" && ! tcp_fire "$port"; do
            sleep 0.1
            polls=$((polls + 1))
        done
        job_running "$SERVER_PID" && break
        stop_server
        port=""
        attempt=$((attempt + 1))
    done
    if [ -z "$port" ]; then
        fail "TLS $suite" "openssl s_server did not start"
        return
    fi
    for c in "$WORK/tls_cli.copy" "$WORK/tls_cli.ref"; do
        got=$(run_bin 30 "$c" "$port" "$cert" "$host" </dev/null 2>&1)
        if [ "$got" = "$want" ]; then
            pass "TLS $suite $(basename "$cert") $host: $(basename "$c")"
        else
            fail "TLS $suite $(basename "$cert") $host: $(basename "$c")" "got: $got"
        fi
    done
    stop_server
}
# The http client (std/http.y) against test/y/net/http_srv.y: one-shot
# requests (Content-Length, chunked, a redirect, POST, a header, HEAD, a
# 404) and a session (cookies, a default header, one kept connection,
# Connection: close).
HTTP_EXPECTED="200 OK 11 hello world
200 chunked b'ab' abcdefgh 8
twice hello world b'hello world' 4 4
200 true hello world
200 POST posted body
same-origin 200 true
cross-origin 200 -1 34
custom value
200 11 []
404 no /nothing
cookies: anon
cookies: sid=abc123; theme=dark
header: from session
same connection: true
put: PUT put body
bye then a new one: true
quit: quit"

test_http_client() {
    local c="$1" attempt=0 port="" log polls got
    while [ "$attempt" -lt 20 ]; do
        port="$(random_port)"
        start_server "$WORK/http_srv.copy" "$port" 0
        log="$WORK/http_srv.copy-$port.log"
        polls=0
        while [ "$polls" -lt 50 ] && job_running "$SERVER_PID" && ! grep -q ready "$log" 2>/dev/null; do
            sleep 0.1
            polls=$((polls + 1))
        done
        grep -q ready "$log" 2>/dev/null && break
        stop_server
        port=""
        attempt=$((attempt + 1))
    done
    if [ -z "$port" ]; then
        fail "http client" "the test server did not start"
        return
    fi
    got=$(run_bin 30 "$c" "$port" </dev/null 2>&1)
    if [ "$got" = "$HTTP_EXPECTED" ]; then
        pass "http client: $(basename "$c")"
    else
        fail "http client: $(basename "$c")" "got: $got"
    fi
    stop_server
}
if compile_server_pair http_srv && compile_server_pair http_cli; then
    test_http_client "$WORK/http_cli.copy"
    test_http_client "$WORK/http_cli.ref"
fi

if command -v openssl >/dev/null 2>&1; then
    if compile_server_pair tls_cli; then
        openssl req -x509 -newkey rsa:2048 -keyout "$WORK/rsa_key.pem" -out "$WORK/rsa.pem" -days 2 -nodes \
            -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -keyout "$WORK/ec_key.pem" -out "$WORK/ec.pem" \
            -days 2 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1
        tls_case TLS_AES_128_GCM_SHA256 "$WORK/rsa.pem" "$WORK/rsa_key.pem" localhost \
            "suite 4865 alpn [http/1.1] matched true HTTP/1.0 200 ok true err []" "-alpn http/1.1"
        tls_case TLS_AES_256_GCM_SHA384 "$WORK/rsa.pem" "$WORK/rsa_key.pem" localhost \
            "suite 4866 alpn [] matched false HTTP/1.0 200 ok true err []"
        tls_case TLS_CHACHA20_POLY1305_SHA256 "$WORK/ec.pem" "$WORK/ec_key.pem" localhost \
            "suite 4867 alpn [] matched false HTTP/1.0 200 ok true err []"
        tls_case TLS_AES_256_GCM_SHA384 "$WORK/ec.pem" "$WORK/ec_key.pem" 127.0.0.1 \
            "ERROR certificate is not valid for 127.0.0.1"
        # A certificate that names the address in an iPAddress SAN. It used to be
        # refused -- names_host read only c.dns -- while the SAME certificate with
        # DNS:127.0.0.1 added was accepted, and `openssl s_client -CAfile` verifies
        # it (SUGGESTIONS.md 14). The case above stays: that certificate has no IP
        # SAN, so refusing it for an address is still right.
        openssl req -x509 -newkey rsa:2048 -keyout "$WORK/ip_key.pem" -out "$WORK/ip.pem" -days 2 -nodes \
            -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
        tls_case TLS_AES_128_GCM_SHA256 "$WORK/ip.pem" "$WORK/ip_key.pem" 127.0.0.1 \
            "suite 4865 alpn [] matched false HTTP/1.0 200 ok true err []"
        # https: the http client against `openssl s_server -WWW`
        if [ -x "$WORK/http_cli.copy" ]; then
            echo "hello over tls" > "$WORK/hello.txt"
            local_port="$(random_port)"
            (cd "$WORK" && exec timeout --kill-after=1 20 openssl s_server -accept "$local_port" \
                -cert "$WORK/ec.pem" -key "$WORK/ec_key.pem" -WWW -quiet </dev/null >/dev/null 2>&1) &
            SERVER_PID=$!
            PIDS+=("$SERVER_PID")
            polls=0
            while [ "$polls" -lt 50 ] && ! tcp_fire "$local_port"; do
                sleep 0.1
                polls=$((polls + 1))
            done
            for c in "$WORK/http_cli.copy" "$WORK/http_cli.ref"; do
                got=$(run_bin 30 "$c" "$local_port" "$WORK/ec.pem" </dev/null 2>&1)
                want="200 hello over tls []
0 [certificate is not valid for 127.0.0.1]"
                if [ "$got" = "$want" ]; then
                    pass "https client: $(basename "$c")"
                else
                    fail "https client: $(basename "$c")" "got: $got"
                fi
            done
            stop_server
        fi
    fi
else
    skip "TLS client" "openssl is not installed"
fi

if [ "$http_ok" -eq 1 ]; then
    test_http "$WORK/srv_http.copy" "C copy"
    test_http "$WORK/srv_http.ref" "reference"
fi
if [ "$tcp_ok" -eq 1 ]; then
    test_tcp "$WORK/srv_tcp.copy" "C copy"
    test_tcp "$WORK/srv_tcp.ref" "reference"
    test_tcp_accept_leak "$WORK/srv_tcp.copy" "C copy"
    test_tcp_accept_leak "$WORK/srv_tcp.ref" "reference"
fi

print_summary "test_net"
