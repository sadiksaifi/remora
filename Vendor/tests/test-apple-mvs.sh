#!/bin/bash
# Owned synthetic vectors and bounded fuzzing, then the same streams beside Screen Sharing's own
# decoder. No sockets or saved desktop data.
# Usage: test-apple-mvs.sh [fuzz iterations | bench]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/remora-mvs.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
if [[ ${1:-} == bench ]]; then
    # Partial-update timings with the Release engine's flags (CMake Release in build-vnc.sh), no sanitizers.
    clang -std=c17 -Wall -Wextra -Werror -O3 -DNDEBUG -I "$ROOT/apple-mvs" \
        "$ROOT/apple-mvs/mvs.c" "$ROOT/tests/test_mvs.c" "$ROOT/tests/apple_oracle.c" -o "$BUILD/bench_mvs"
    "$BUILD/bench_mvs" bench
    exit
fi
clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined,integer,nullability \
    -fno-sanitize-recover=all -fno-omit-frame-pointer -g -O1 -I "$ROOT/apple-mvs" \
    "$ROOT/apple-mvs/mvs.c" "$ROOT/tests/test_mvs.c" "$ROOT/tests/apple_oracle.c" -o "$BUILD/test_mvs"
ASAN_OPTIONS=abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 "$BUILD/test_mvs" "${1:-200000}"
# The oracle: the same tests with Screen Sharing's decoder beside Remora's. Built without the
# sanitizers, which cannot follow Apple's code. It skips where that decoder cannot be called.
clang -std=c17 -Wall -Wextra -Werror -O2 -I "$ROOT/apple-mvs" \
    "$ROOT/apple-mvs/mvs.c" "$ROOT/tests/test_mvs.c" "$ROOT/tests/apple_oracle.c" -o "$BUILD/oracle_mvs"
"$BUILD/oracle_mvs" oracle
