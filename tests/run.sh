#!/bin/sh
# Runs every BRAT test harness with LuaJIT. Usage: sh tests/run.sh
cd "$(dirname "$0")/.." || exit 1
LUA="${LUA:-luajit}"
command -v "$LUA" >/dev/null 2>&1 || LUA="/c/Users/Brad/AppData/Local/Programs/LuaJIT/bin/luajit.exe"
fail=0
for f in tests/test_*.lua; do
    echo "== $f"
    "$LUA" "$f" . || fail=1
done
[ $fail -eq 0 ] && echo "ALL HARNESSES PASSED" || echo "SOME HARNESSES FAILED"
exit $fail
