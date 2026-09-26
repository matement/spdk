#!/usr/bin/env bash
#
# build_and_catch_errors.sh
#
# Runs `make` (or any command you pass in), captures the full output,
# and extracts just the error/warning lines into a separate summary file.
#
# Usage:
#   ./build_and_catch_errors.sh                     # runs: make -j$(nproc)
#   ./build_and_catch_errors.sh -j56 CUDA_ARCH=75    # runs: make -j56 CUDA_ARCH=75
#
# Any arguments you pass are forwarded straight to `make`. Logs are
# overwritten every run (not timestamped) so you always find the latest
# results at the same two filenames.

set -uo pipefail

FULL_LOG="build_full.log"
ERROR_LOG="build_errors.txt"

# Default to `make -j$(nproc)` if no arguments given, otherwise forward all
# arguments straight to `make`.
if [ "$#" -eq 0 ]; then
    CMD=(make -j"$(nproc)")
else
    CMD=(make "$@")
fi

echo "Running: ${CMD[*]}"
echo "Full log:  $FULL_LOG"
echo "Error log: $ERROR_LOG"
echo

# Run the build, tee full output to disk while still showing it live in the terminal.
"${CMD[@]}" 2>&1 | tee "$FULL_LOG"
BUILD_EXIT_CODE=${PIPESTATUS[0]}

echo
echo "== Build finished with exit code $BUILD_EXIT_CODE ==" | tee -a "$FULL_LOG"

# Pull out error-relevant lines. We grab a few lines of context before each
# match too, since compiler/linker errors are often more useful with the
# line right above them (e.g. the file/function the error occurred in).
grep -n -i -B3 \
    -E "error|undefined reference|fatal|Error [0-9]+|\*\*\*" \
    "$FULL_LOG" > "$ERROR_LOG"

if [ -s "$ERROR_LOG" ]; then
    ERROR_COUNT=$(grep -c -i -E "error|undefined reference|fatal" "$ERROR_LOG")
    echo "Found ~$ERROR_COUNT error-related lines. See: $ERROR_LOG"
else
    echo "No errors found in output."
    rm -f "$ERROR_LOG"
fi

exit "$BUILD_EXIT_CODE"
