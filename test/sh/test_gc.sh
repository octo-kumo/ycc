#!/bin/bash
# The collector under a cap: the reason it exists.
#
# A threaded program used to leak everything it allocated once a thread was
# spawned -- y_gc_collect returns immediately when y_heap+24 (the
# spawned-a-thread flag) is set -- so its memory grew with the WORK, not with
# what it kept. It now stops the world at the allocator's slow path, scans
# every parked or blocked thread's stack from its control block, and reclaims
# both heaps. This suite is the measurement: two threads of 300k allocations
# (~90 MB of garbage) must run inside a small cap.
#
# --gc=never is the control. With the collector omitted the same workload does
# not fit the cap, which is what makes the first case mean something.
set -u

source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d /tmp/ygc_XXXXXX)
trap 'rm -rf "$WORK"' EXIT

THR="$ROOT/test/y/native/t385_gc_threads_alloc.y"
EXPECT="7088890
7088890"
CAP="${YGC_CAP_KB:-65536}"

for spec in "cycc:${CYCC:-$ROOT/cycc}" "ynew:${YREF:-$ROOT/ynew}"; do
    tag="${spec%%:*}"
    cc="${spec#*:}"
    if [ ! -x "$cc" ]; then
        skip "gc [$tag]" "$cc not built"
        continue
    fi
    b="$WORK/thr_$tag"
    if ! ( cd "$ROOT" && ulimit -v "${YPROG_MEM_KB:-3670016}"; \
           timeout "$((60 * ${YTIMEOUT_SCALE:-1}))" "$cc" "$THR" -o "$b" ) 2>/dev/null; then
        fail "gc [$tag] compiles the threaded allocation fixture" ""
        continue
    fi
    got=$( ( cd "$ROOT" && ulimit -v "$CAP"; \
             timeout "$((120 * ${YTIMEOUT_SCALE:-1}))" "$b" </dev/null ) 2>&1 )
    if [ "$got" = "$EXPECT" ]; then
        pass "gc [$tag] two threads x 300k allocations fit in $((CAP / 1024)) MiB"
    else
        fail "gc [$tag] threaded allocation under the cap" "$(echo "$got" | tr '\n' ' ')"
    fi
    # --gc-stress: a cycle at EVERY allocating slow path, two threads. If a
    # root is missed or the stop-the-world is unsound, this is where it shows.
    STR="$ROOT/test/y/native/t389_gc_stress_threads.y"
    if ( cd "$ROOT" && ulimit -v "${YPROG_MEM_KB:-3670016}"; \
         timeout "$((120 * ${YTIMEOUT_SCALE:-1}))" "$cc" --gc-stress "$STR" -o "$b.st" ) 2>/dev/null; then
        got3=$( ( cd "$ROOT" && ulimit -v "$CAP"; \
                  timeout "$((300 * ${YTIMEOUT_SCALE:-1}))" "$b.st" </dev/null ) 2>&1 )
        want3=$(cat "$ROOT/test/y/native/t389_gc_stress_threads.expected")
        if [ "$got3" = "$want3" ]; then
            pass "gc [$tag] two threads survive a cycle at every allocation (--gc-stress)"
        else
            fail "gc [$tag] --gc-stress threads" "$(echo "$got3" | tr '\n' ' ')"
        fi
    else
        fail "gc [$tag] compiles the --gc-stress fixture" ""
    fi
    if ( cd "$ROOT" && ulimit -v "${YPROG_MEM_KB:-3670016}"; \
         timeout "$((60 * ${YTIMEOUT_SCALE:-1}))" "$cc" --gc=never "$THR" -o "$b.ng" ) 2>/dev/null; then
        got2=$( ( cd "$ROOT" && ulimit -v "$CAP"; \
                  timeout "$((120 * ${YTIMEOUT_SCALE:-1}))" "$b.ng" </dev/null ) 2>&1 )
        if [ "$got2" = "$EXPECT" ]; then
            fail "gc [$tag] --gc=never fits the cap" "the fixture does not discriminate"
        else
            pass "gc [$tag] --gc=never runs out of memory on the same workload"
        fi
    fi
done

print_summary gc
