#!/bin/bash
# Owned synthetic vectors and bounded fuzzing. No sockets or saved desktop data.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/remora-mvs.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined,integer,nullability \
    -fno-sanitize-recover=all -fno-omit-frame-pointer -g -O1 -I "$ROOT/apple-mvs" \
    "$ROOT/apple-mvs/mvs.c" "$ROOT/tests/test_mvs.c" -o "$BUILD/test_mvs"
ASAN_OPTIONS=abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 "$BUILD/test_mvs" "${1:-200000}"
