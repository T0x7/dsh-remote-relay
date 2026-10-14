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

echo "4. a safe token must NOT vouch for a leak beside it"
# This is the real regression, not a synthetic one. The guard used to allowlist
# the whole line, so `127.0.0.1` on a line exempted the private hostname sitting
# next to it — which is exactly how a relay hostname sat in the project's own
# progress log while every scan came back clean. An allowlist coarser than the
# detection cannot catch anything: the safe token is always available to hide
# behind. Planted as a separate fixture so the earlier planted-leak assertions
# keep their own corpus.
printf '%s\n' \
  '# TEMPORARY scanner self-test fixture — must never be committed.' \
  'engine at `127.0.0.1:3080`, trusted-host `relay.my-private-domain.top`' > "$FIXTURE"
git add "$FIXTURE" 2>/dev/null

if bash "$SCAN" >/tmp/scan-cosmetic.$$ 2>&1; then
  echo "   FAIL: a loopback address on the line vouched for the hostname beside it" >&2
  rc=1
elif grep -qE 'my-private-domain' /tmp/scan-cosmetic.$$; then
  echo "   ok — caught the hostname even though its line also held 127.0.0.1"
else
  echo "   FAIL: scanner rejected the tree but not for the leak it planted" >&2
  cat /tmp/scan-cosmetic.$$ >&2
  rc=1
fi

# ...and the inverse must stay true, or the tightening above turns into noise:
# a line whose ONLY match is safe must still pass.
echo "5. an all-safe line must still pass"
printf '%s\n' \
  '# TEMPORARY scanner self-test fixture — must never be committed.' \
  'engine at `127.0.0.1:3080`, docs at `example.com`' > "$FIXTURE"
git add "$FIXTURE" 2>/dev/null
if bash "$SCAN" >/tmp/scan-safeline.$$ 2>&1; then
  echo "   ok — an all-safe line still passes (no false positive from the tightening)"
else
  echo "   FAIL: a line of nothing but allowlisted tokens was reported" >&2
  cat /tmp/scan-safeline.$$ >&2
  rc=1
fi
rm -f "/tmp/scan-cosmetic.$$" "/tmp/scan-safeline.$$" 2>/dev/null

cleanup
rm -f "/tmp/scan-out.$$" 2>/dev/null

echo "6. a /root/ deployment path must be caught"
# Not synthetic in spirit: the repo shipped two of these (the production
# deploy directory under /root, in a progress log and a field-notes table)
# through a release while rule 5 matched only /Users and /home. The macOS and
# Linux-desktop spellings were covered; the one a VPS uses was not.
printf '%s\n' \
  '# TEMPORARY scanner self-test fixture — must never be committed.' \
  'deploy dir: a-private-deploy-dir (rsync, no git)' > "$FIXTURE"
git add "$FIXTURE" 2>/dev/null
if bash "$SCAN" >/tmp/scan-root.$$ 2>&1; then
  echo "   FAIL: scanner passed a /root/ deployment path" >&2
  rc=1
elif grep -q 'SCAN-SELFTEST.md' /tmp/scan-root.$$; then
  echo "   ok — caught the /root/ path (the rule that missed the VPS spelling)"
else
  echo "   FAIL: scanner rejected the tree but not for the planted /root/ path" >&2
  cat /tmp/scan-root.$$ >&2
  rc=1
fi
cleanup
rm -f "/tmp/scan-root.$$" 2>/dev/null

echo "7. commit messages: placeholders and loopback pass, real paths do not"
# Rule 6 needs commits to look at, and this self-test must not leave any
# behind. A commit is minted with commit-tree (reusing HEAD's tree, so the
# working tree is untouched) and parked on a scratch ref, because the rule
# reads `git rev-list --all`. The ref is removed whatever happens; the objects
# it pinned are unreferenced and gc collects them, which is the same residue
# class as a dangling stash entry and far cheaper than a test-only branch.
SCRATCH=refs/selftest/scan-secrets
drop_scratch() { git update-ref -d "$SCRATCH" 2>/dev/null; return 0; }
trap 'cleanup; drop_scratch' EXIT
HEADTREE=$(git rev-parse HEAD^{tree})

msg_case() {   # msg_case <expected: pass|fail> <commit message>
  local want=$1 msg=$2 c
  c=$(printf '%s' "$msg" | git commit-tree "$HEADTREE" 2>/dev/null) || return 1
  git update-ref "$SCRATCH" "$c" 2>/dev/null || return 1
  # Ask whether THIS commit was flagged, not whether the scan came back clean.
  # The repository's own history may carry real findings — those are the
  # guard's job, not this case's — and a case that inherits them cannot
  # express "this message is fine".
  bash "$SCAN" --history >/tmp/scan-msg.$$ 2>&1
  if grep -q "commit message ${c:0:8} " /tmp/scan-msg.$$; then got=fail; else got=pass; fi
  if [ "$got" = "$want" ]; then
    echo "   ok — $want as expected"
  else
    echo "   FAIL: expected $want, got $got for: $msg" >&2
    grep "commit message ${c:0:8} " /tmp/scan-msg.$$ | head -3 >&2
    rc=1
  fi
  drop_scratch
}

msg_case pass 'engine at 127.0.0.1:3080, bridge 172.28.0.0/24, publish 0.0.0.0:8080
sample path /Users/someone/proj'
msg_case pass 'HTTPS_PROXY=127.0.0.1:7897 did not work either'
msg_case fail 'deploy dir is a-private-deploy-dir, rsync, no git'
msg_case fail 'HOME=/Users/jdoe leaked from the environment'
rm -f "/tmp/scan-msg.$$" 2>/dev/null
trap cleanup EXIT

echo "8. clean tree must pass again"
if bash "$SCAN" >/dev/null 2>&1; then
  echo "   ok"
else
  echo "   FAIL: scanner still rejects the tree after the fixture was removed" >&2
  rc=1
fi

[ "$rc" -eq 0 ] && echo "selftest: guard behaves"
exit "$rc"
