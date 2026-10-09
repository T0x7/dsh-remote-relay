#!/bin/bash
# Full local verification: install -> build -> test, plus the client-bundle
# contract that no unit test can see from the sources alone.
#
# Order matters. `plugin/tests/client-bundle.spec.ts` reads the BUILT
# lib/client.js, so `build` must run before `test` or those specs skip.
#
# Specs whose requirements are unmet skip with a printed reason rather than
# failing, so this script also reports which layers actually executed — a green
# run with skips is not the same as a green run without them.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

fail=0
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
note() { printf '  \033[33mskip\033[0m  %s\n' "$1"; }

step "node / pnpm"
node -v; pnpm -v

step "pnpm install"
if pnpm install; then ok "dependencies installed"; else bad "pnpm install"; fi

step "pnpm -r build"
if pnpm -r build; then ok "all packages built"; else bad "build"; fi

# The browser half ships as lazy-CJS: a plain script that registers exactly one
# factory under the package name. A missing build, a renamed package or a stray
# `export` all break the mount silently in the browser, so check the artifact
# directly instead of trusting that the build command exited 0.
step "client bundle contract (plugin/lib/client.js)"
BUNDLE="$ROOT/plugin/lib/client.js"
PKG=$(node -p "require('$ROOT/plugin/package.json').name")
if [ ! -f "$BUNDLE" ]; then
  bad "$BUNDLE not found — build:client did not emit it"
else
  ok "artifact exists ($(wc -c <"$BUNDLE" | tr -d ' ') bytes)"

  head -c 4000 "$BUNDLE" | grep -q "window.__ModuleLoader__.load" \
    && ok "registers through window.__ModuleLoader__" \
    || bad "no window.__ModuleLoader__.load in the head"

  head -c 4000 "$BUNDLE" | grep -q "id: \"$PKG\"" \
    && ok "factory id is the package name ($PKG)" \
    || bad "factory id does not match package name $PKG"

  grep -qE '(^|[^A-Za-z0-9_$.])export[[:space:]]' "$BUNDLE" \
    && bad "found ESM 'export' — the bundle must stay a classic script" \
    || ok "no ESM export syntax"

  tail -c 4000 "$BUNDLE" | grep -q "return module.exports" \
    && ok "module.exports returned in the footer" \
    || bad "missing the module.exports footer"

  # `@deepseek-ai/dsh-client-*` are platform modules the Host supplies through
  # the loader; a literal require means the bundle is reaching for one directly
  # and will fail in the browser. Same rule as client-bundle.spec.ts.
  grabbed=$(grep -oE "require\(\"@deepseek-ai/dsh-client-[^\"]+\"\)" "$BUNDLE" 2>/dev/null \
    | sort -u | tr '\n' ' ')
  [ -z "$grabbed" ] \
    && ok "no direct @deepseek-ai/dsh-client-* require" \
    || bad "bundle requires platform module(s) directly: $grabbed"
fi

step "dsh binary (loader composition)"
if command -v dsh >/dev/null 2>&1; then
  ok "dsh on PATH ($(dsh --version 2>&1 | head -1))"
else
  note "dsh not on PATH — loader-composition.e2e.ts will skip its REAL-composition spec"
fi

step "pnpm -r test"
if pnpm -r test 2>&1 | tee /tmp/dsh-verify-test.log; then
  ok "all test suites passed"
else
  bad "test suites"
fi

# A suite that skipped everything still exits 0, so read the counts explicitly.
if grep -qE 'skipped +[1-9]' /tmp/dsh-verify-test.log; then
  printf '\n'
  note "some specs SKIPPED — these layers did not run:"
  grep -oE '\[[a-z-]+\] skipped: [^\n]*' /tmp/dsh-verify-test.log | sort -u | sed 's/^/        /'
  printf '        (the passing count above excludes them; check the reasons above)\n'
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[32mVERIFICATION PASSED\033[0m (with the skips noted above, if any)\n'
else
  printf '\033[31mVERIFICATION FAILED\033[0m\n'
fi
exit "$fail"
