#!/bin/sh
# Regenerate golden vectors from the canonical Python sm20/ package, then run
# the Lua parity harness and the DB upgrade drill under every available Lua
# interpreter.
set -e
cd "$(dirname "$0")/.."

python3 tests/golden/generate_vectors.py

status=0
ran_any=0
for LUA in lua5.1 luajit lua; do
  if command -v "$LUA" >/dev/null 2>&1; then
    # avoid running plain "lua" when it is the same binary as lua5.1
    if [ "$LUA" = "lua" ] && command -v lua5.1 >/dev/null 2>&1 \
       && [ "$(readlink -f "$(command -v lua)")" = "$(readlink -f "$(command -v lua5.1)")" ]; then
      continue
    fi
    ran_any=1
    echo
    echo "=== parity harness: $LUA ==="
    "$LUA" tests/run_tests.lua || status=1
    echo
    echo "=== db upgrade drill: $LUA ==="
    "$LUA" tests/run_db_drill.lua || status=1
  fi
done

if [ "$ran_any" = "0" ]; then
  echo "no lua interpreter found (need lua5.1 or luajit)" >&2
  exit 1
fi
exit $status
