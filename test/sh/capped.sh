#!/bin/bash
# The Makefile's SHELL: every recipe line runs under an address-space cap
# below 4 GB (past 4 GB this machine goes down), so no compile, test,
# benchmark or valgrind run a target starts can take it. The cap is soft:
# lib.sh lifts it for a sanitized compiler (ASan reserves terabytes of
# address space), which ASAN_OPTIONS=hard_rss_limit_mb caps instead.
ulimit -S -v "${YMEM_CAP_KB:-3670016}" || exit 1
exec /bin/sh "$@"
