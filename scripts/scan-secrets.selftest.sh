#!/bin/bash
# Self-test for scripts/scan-secrets.sh.
#
# A leak guard that has never been observed to fail is indistinguishable from
# a guard that does nothing. This plants a known-bad file, asserts the scanner
# rejects it, then removes it and asserts the tree is clean again.
#
# usage: scripts/scan-secrets.selftest.sh
# exit:  0 the guard behaves, 1 it does not
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

SCAN=scripts/scan-secrets.sh
FIXTURE=SCAN-SELFTEST.md
rc=0

cleanup() {
  # Unstage AND remove — unstaging alone leaves the planted leak sitting in
  # the working tree, and the next run then refuses to start because the
  # fixture already exists.
  git rm --cached --quiet "$FIXTURE" >/dev/null 2>&1
  [ -f "$FIXTURE" ] && rm -f "$FIXTURE"
  return 0
}
trap cleanup EXIT

if [ -e "$FIXTURE" ]; then
  echo "selftest: $FIXTURE already exists — refusing to overwrite" >&2
  exit 2
fi

echo "1. clean tree must pass"
if bash "$SCAN" >/dev/null 2>&1; then
  echo "   ok"
else
  echo "   FAIL: scanner rejects the clean tree (false positive)" >&2
  bash "$SCAN" 2>&1 | head -10 >&2
  rc=1
fi

echo "2. planted leak must be rejected"
# printf rather than a here-document: this script has to run in whatever shell
# or CI image the maintainer happens to have, and heredocs are not portable
# across all of them.
printf '%s\n' \
  '# TEMPORARY scanner self-test fixture — must never be committed.' \
  'relay_url: https://relay.my-private-domain.top' \
  'vps: 45.62.113.77' \
  'RELAY_PSK=9f2a1b8c4d6e0f2a1b3c5d7e9f0a2b4c' \
  'psk: 01e9472b027536c7ee911bc134bdd0f4466a85546341a73bcba12e671913458e' \
  'home: /Users/jdoe/Container' > "$FIXTURE"
git add "$FIXTURE" 2>/dev/null

if bash "$SCAN" >/tmp/scan-out.$$ 2>&1; then
  echo "   FAIL: scanner passed a tree with a planted hostname, IP, PSK and home path" >&2
  rc=1
else
  echo "   ok — caught:"
  grep -E '^::error::' /tmp/scan-out.$$ | sed 's/^/     /'
fi

# Each rule must fire on its own; a guard where only one of four rules works
# is the failure mode that got us here.
for rule in 'my-private-domain' '45\.62\.113' 'RELAY_PSK' '/Users/jdoe'; do
  if grep -qE "$rule" /tmp/scan-out.$$; then
    echo "   ok — rule fired: $rule"
  else
    echo "   FAIL — rule did not fire: $rule" >&2
    rc=1
  fi
done

echo "3. a leak in a .md file must be caught"
# The original guard skipped '*.md' outright. This is the specific regression
# this self-test exists to prevent, so assert it against this file's extension.
if grep -q 'SCAN-SELFTEST.md' /tmp/scan-out.$$; then
  echo "   ok — flagged inside a .md file (the old guard skipped these)"
else
  echo "   FAIL — the .md exclusion is back" >&2
  rc=1
fi

cleanup
rm -f "/tmp/scan-out.$$" 2>/dev/null

echo "4. clean tree must pass again"
if bash "$SCAN" >/dev/null 2>&1; then
  echo "   ok"
else
  echo "   FAIL: scanner still rejects the tree after the fixture was removed" >&2
  rc=1
fi

[ "$rc" -eq 0 ] && echo "selftest: guard behaves"
exit "$rc"
