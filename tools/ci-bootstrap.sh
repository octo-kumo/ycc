#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
boot=$(mktemp -d -t ycc-boot.XXXXXX)/ycc
gh release download --pattern ycc --output "$boot" ||
  { echo "no previous release with a 'ycc' asset to bootstrap from" >&2; exit 1; }
chmod 755 "$boot"
echo "BOOT=$boot" >> "${GITHUB_ENV:-/dev/null}"
mkdir -p bootstrap
make ynew BOOT="$boot" </dev/null
make bootstrap-update BOOT="$boot" </dev/null
