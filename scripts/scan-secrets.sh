#!/bin/bash
# Scan tracked files for material that must not reach a public repository.
#
# Lives in scripts/ rather than inline in the CI workflow so it can be run
# locally — an open-source guard that has only ever run in CI is a guard whose
# false positives you find out about at release time. Run it before pushing.
#
# Why this was rewritten: the original check lived in the workflow, skipped
# '*.md' outright (the exact files where a maintainer pastes their own relay
# URL), and hardcoded one private hostname as its only domain rule — which
# both missed every other hostname and published the domain it meant to
# protect. A real leak was in fact committed to a commit message while this
# check existed, so it now covers commit messages too (--scan-history).
#
# FOUR TRAPS, all hit while writing it. Read before changing any pattern:
#
#  1. This runs through `git grep -E`, which is POSIX ERE. There is no \b and
#     no \s. System grep accepts them, so a pattern that looks right in a
#     terminal silently matches nothing here.
#
#  2. The flag is -i (lowercase). -I is an unrelated option meaning "skip
#     binary files"; typing -nEI reads as "extended, ignore case" but runs
#     case-SENSITIVELY, which quietly halved the credential rule — RELAY_PSK=
#     passed the scan while psk: was caught.
#
#  3. `git grep -n` prefixes every hit with `file:line:`. Filtering that whole
#     line against an allowlist means any file whose NAME matches the
#     allowlist exempts all of its contents — an allowlist entry for `.md`
#     exempts every line in every markdown file. So the allowlist is applied
#     to the content only, with the location prefix stripped first.
#
#  4. Trap 3 one level down, and it is the one that let a real relay hostname
#     sit in this repo's own progress log while the guard ran green: the
#     allowlist was still tested against the WHOLE LINE, so a single safe
#     token anywhere on a line exempted every other match on it. The log line
#     `127.0.0.1:3080, trusted-host relay.<private>.top` matched `127.0.0.1`
#     and the real hostname went out with it. An allowlist must be tested at
#     the same granularity as the detection, never coarser — so SAFE is now
#     applied to each match the rule produced, and the line is reported if any
#     one of them is not allowlisted.
#
#  5. Trap 4's own first draft kept the match narrower than the allowlist and
#     so flagged every placeholder: rule 5 matched a single character after the
#     username directory while SAFE allowlists the whole `/Users/someone`. And
#     the token extraction dropped the `-i` the main pass runs with, so an
#     UPPERCASE match such as `PSK=` extracted as the empty string and was then
#     reported as "nothing vouched for this line" — a false positive wearing the
#     costume of the new failure mode. Both halves of the pattern must be
#     identical to the rule's, or the guard invents leaks instead of finding
#     them. (Note the consequence for prose: this file's own comments are
#     scanned like any other, so a truncated sample like the one that caused
#     trap 5 is itself reported — reword rather than widen an exemption.)
#
# Every rule below is verified end-to-end against a planted leak; see
# scripts/scan-secrets.selftest.sh. Re-run that after touching a pattern.
#
# usage: scripts/scan-secrets.sh            scan the working tree (tracked files)
#        scripts/scan-secrets.sh --history  also scan every commit message
# exit:  0 clean, 1 something matched, 2 the scan itself failed
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

SCAN_HISTORY=0
[ "${1:-}" = "--history" ] && SCAN_HISTORY=1

# Every tracked file, and the documentation subset. A rule can be scoped to
# the latter: once the file list is passed explicitly, git treats any extra
# argument as a literal path rather than a glob, so '*.md' would silently match
# nothing. Filter the array instead.
files=()
doc_files=()
while IFS= read -r f; do
  files+=("$f")
  case "$f" in *.md) doc_files+=("$f");; esac
done < <(git ls-files)
if [ "${#files[@]}" -eq 0 ]; then
  echo "scan-secrets: no tracked files — is this a git repository?" >&2
  exit 2
fi

# Let through: RFC 2606 / RFC 5737 reserved names, loopback, the public
# resolvers and IP-echo services the relay legitimately calls, Docker's
# internal host, and Docker Hub. Note this is matched against CONTENT — see
# trap 2 above, which is why no file-extension entries belong here.
#
# The tail `|/(Users|home)/someone` is NOT a hole. `someone` is this repo's
# canonical redaction placeholder — the app's own path-redaction tests prove
# that `/Users/<name>/…` gets rewritten, and they need a realistic-looking
# sample to do it with. Without this entry rule 5 fires on a clean tree, the
# guard is permanently red, and the first person to see that learns to ignore
# it. Do not "tidy" it away; if you need another placeholder, use one that is
# clearly fake and add it here next to this one.
SAFE='example\.(com|org|net)|\.test([^a-z]|$)|\.invalid([^a-z]|$)|\.example([^a-z]|$)|localhost|127\.0\.0\.1|0\.0\.0\.0|255\.255\.255|8\.8\.8\.8|9\.9\.9\.9|1\.1\.1\.1|host\.docker\.internal|icanhazip\.com|ipify\.org|api\.ip\.sb|docker\.io|maven\.apache\.org|dsh-host-app\.app|session\.page|keepachangelog\.com|contributor-covenant\.org|github\.com|githubusercontent\.com|flutter\.dev|dart\.dev|pub\.dev|npmjs\.com|nodejs\.org|anthropic\.com|openai\.com|developer\.android\.com|apple\.developer\.com|schemas\.android\.com|schemas\.googleapis\.com|w3\.org|pub\.flutter-io\.cn|storage\.flutter-io\.cn|fonts\.googleapis\.com|fonts\.gstatic\.com|services\.gradle\.org|storage\.googleapis\.com|maven\.aliyun\.com|mirrors\.cloud\.tencent\.com|apple\.com|dl\.google\.com|maven\.google\.com|repo1\.maven\.org|plugins\.gradle\.org|dsh-remote-relay-default-insecure-psk|local-smoke-psk-not-for-production|(^|[^0-9A-Za-z.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3})([^0-9]|$)|/(Users|home)/someone([^a-zA-Z0-9-]|$)'

# The guard's own fixture file, exempted by exact path. This is deliberate and
# narrow: scan-secrets.selftest.sh exists to carry fake leaks, so its contents
# are known-bad by construction. Compare trap 3 — a blanket '*.md' style
# exemption is what made the original guard useless; a single named file whose
# only job is to hold fakes is the allowlist pattern, not that trap.
FIXTURE_FILE=scripts/scan-secrets.selftest.sh

rc=0

# Strip the `file:line:` prefix before allowlisting, so an allowlist entry can
# only ever match the text itself and never the file's name.
#
# A pipe into `while read`, not `<<< "$out"`: a here-document needs a writable
# temp file, and on a host where it cannot create one the whole function
# silently yields nothing — which reads as "no leaks found". This guard is
# rewritten to fail closed instead of failing open.
scan_into() {   # sets the global SCAN_HITS, and rc=2 if the mechanism broke
  local out st line content toks unsafe set=("$@")
  SCAN_HITS=''
  out=$(git grep -niE "${set[0]}" -- "${set[@]:1}" 2>/dev/null)
  st=$?
  if [ "$st" -gt 1 ]; then
    echo "scan-secrets: grep failed (status $st) for rule: ${set[0]}" >&2
    rc=2
    return 0
  fi
  [ -z "$out" ] && return 0
  # The `while` runs in a subshell but only emits text, so collecting its
  # output here is safe; assigning rc inside one would not be.
  SCAN_HITS=$(printf '%s\n' "$out" | while IFS= read -r line; do
    # The guard's own fakes: skip by exact path prefix. (A case pattern with a
    # quoted variable matches literally rather than as a glob, which on this
    # bash is a syntax surprise — the prefix test below is the portable form.)
    if [ "${line#"$FIXTURE_FILE":}" != "$line" ]; then continue; fi
    content=${line#*:}      # drop the path
    content=${content#*:}   # drop the line number
    # Trap 4: allowlist each MATCH, not the line. `toks` is what this rule
    # actually flagged on this line; SAFE is tested against those one at a
    # time, so a loopback address sharing the line cannot vouch for a hostname
    # it happens to sit next to. No tokens means grep -o disagreed with the
    # -n pass, which leaves nothing to vouch for the line — treat it as unsafe
    # rather than silently dropping it.
    toks=$(printf '%s' "$content" | grep -oiE "${set[0]}" 2>/dev/null)
    unsafe=$(printf '%s\n' "$toks" | while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      printf '%s' "$tok" | grep -qE "$SAFE" || printf '%s\n' "$tok"
    done)
    if [ -z "$toks" ] || [ -n "$unsafe" ]; then
      printf '%s\n' "$line"
    fi
  done)
}

report() {      # report <label> <pattern> [docs|skip-tests]
  local label=$1 pattern=$2
  if [ "${3:-}" = "docs" ]; then
    scan_into "$pattern" "${doc_files[@]}"
  elif [ "${3:-}" = "skip-tests" ]; then
    # Test files legitimately carry `/Users/<name>/…` samples: they prove the
    # app's own path redaction rewrites such a path, and inventing a
    # different-looking sample would weaken those tests. A test file is not
    # where a maintainer's real username shows up.
    local corpus=()
    local f
    for f in "${files[@]}"; do
      case "$f" in */test/*|*/tests/*) ;; *) corpus+=("$f") ;; esac
    done
    scan_into "$pattern" "${corpus[@]}"
  else
    scan_into "$pattern" "${files[@]}"
  fi
  if [ -n "${SCAN_HITS:-}" ]; then
    echo "::error::$label"
    printf '%s\n' "$SCAN_HITS" | head -20
    rc=1
  fi
}

# 1. IPv4 literals — a public deployment host or a VPS address. The leading
#    [^0-9A-Za-z.] guard is what keeps `v3.128.2.1` (a version) and
#    `tok5.1.2.3.BBBB` (a test token) out: in both, the first digit group is
#    preceded by a word character or another dot. Private ranges are allowed
#    through SAFE, not here — an RFC1918 address in a compose file is ordinary
#    documentation, and a public VPS address is the thing worth flagging.
report "possible public deployment IP committed" \
  '(^|[^0-9A-Za-z.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'

# 2. URL hosts. Anchored on `://` so ordinary dotted source constructs
#    (res.headers.get, this.config.psk, cordis.patch.yml) cannot match.
report "possible private hostname committed" \
  '://[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)+'

# 3. Bare hostnames, DOCS ONLY. Over source this rule is unusable: `logger.info`,
#    `store.load`, `route.delete` and `d.online` are indistinguishable from a
#    hostname, and a rule that fires on every property access gets switched off
#    within a day. Prose is where a maintainer actually pastes their own relay,
#    which is exactly what the original guard missed by skipping '*.md'.
#    `sh` is deliberately absent from the TLD list: it is a real ccTLD, but in a
#    repo full of build-dist.sh it fires on every filename.
report "possible private hostname committed (docs)" \
  '(^|[^0-9A-Za-z./-])[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*\.(top|xyz|site|online|club|icu|vip|shop|store|blog|live|space|website|tech|cloud|io|dev|app|ai|me|tv|cc|pw|work|team|zone|life|world|fun|link|click|one|run|page|wiki|news|art|studio|design|health|fund|gg|la|info|biz|us|uk|de|fr|jp|cn|ru|tw|hk|sg|au|ca|nl|se|br|in|kr|za|mx|es|pl|cz|at|ch|be|dk|ie|nz|pt|gr|il|tr|co|com|net|org)([^a-z]|$)' \
  docs

# 4. Credentials assigned to a secret-shaped name. The value must be 24+
#    characters: this project mints PSKs with `openssl rand -hex 32` (64 hex
#    chars), while everything shorter in the tree is a test fixture or a bare
#    identifier — 'test-engine-token', 'token_secret_123', and
#    `const ENGINE_TOKEN = readDshBindToken()` all sit below the floor.
report "possible credential committed" \
  '(psk|passwd|password|secret|token|api[_-]?key|webhook)["'"'"']?[ 	]*[:=][ 	]*["'"'"']?[A-Za-z0-9+/=_-]{24,}'

# 5. Absolute home paths — a username is PII even when the host is masked.
#    `/root` is in the set for the same reason `/Users` and `/home` are: a
#    deployment directory published under root names both the host's layout and
#    the project that lives there, and it sat in this repo's own docs for a
#    release because only the macOS and Linux-desktop spellings were covered.
#    The pattern spans the whole leading path segment, not just its first
#    character: SAFE allowlists the full `/Users/someone`, so a one-letter match
#    could never be recognised as the placeholder it is (trap 5) and every
#    redaction sample in the tree would read as a leak.
#    Test files are exempt **by path**: they must carry a realistic
#    `/Users/<name>/…` sample to prove the app's own redaction actually
#    rewrites it, and inventing a different-looking path would weaken that
#    test. A test file is not a place a maintainer's real username appears.
report "possible personal home path committed" \
  '/(Users|home|root)/[a-zA-Z][a-zA-Z0-9._-]*' skip-tests

# 6. Commit messages. A real leak rode along in one: a long message was passed
#    through a shell that spliced its whole environment into it, committing
#    HOME, USER and the machine hostname. The tree scan above cannot see that.
#
#    Two things this rule needed to stop flagging things that are not leaks,
#    without giving up what it catches:
#
#    a) The env-var alternative used to stop at the `=`, so the token handed to
#       the allowlist was the literal string `HTTPS_PROXY=` — which matches
#       nothing in SAFE, and made `HTTPS_PROXY=127.0.0.1:7897` indistinguishable
#       from a spliced `HOME=/Users/<real name>`. Same defect as trap 5, one
#       level up: the token has to span the whole thing the rule is about, or
#       the allowlist is testing a fragment that carries no information. It now
#       runs to the end of the value.
#    b) It had no allowlist at all, which is the trap-4 shape again: strictly
#       coarser than the tree rules above, so prose describing a leak tripped it
#       (a commit explaining that loopback is allowlisted next to a hostname it
#       had just removed). SAFE is applied per token here too.
if [ "$SCAN_HISTORY" = "1" ]; then
  MSG_RULE='^(HOME|LOGNAME|HOSTNAME|PATH|USER|BASH_ARGV|BASH_EXECUTION_STRING|HTTPS_PROXY|GIT_TEMPLATE_DIR)=[^[:space:]]*|/(Users|home|root)/[a-zA-Z][a-zA-Z0-9._-]*|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
  for c in $(git rev-list --all); do
    msg=$(git log -1 --format=%B "$c")
    toks=$(printf '%s' "$msg" | grep -oiE "$MSG_RULE" 2>/dev/null)
    unsafe=$(printf '%s\n' "$toks" | while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      printf '%s' "$tok" | grep -qE "$SAFE" || printf '%s\n' "$tok"
    done)
    if [ -n "$unsafe" ]; then
      echo "::error::commit message ${c:0:8} carries environment or personal data"
      printf '%s\n' "$unsafe" | head -10
      rc=1
    fi
  done
fi

if [ "$rc" -eq 0 ]; then
  echo "clean: ${#files[@]} tracked files scanned$( [ "$SCAN_HISTORY" = 1 ] && echo ' + all commit messages')"
fi
exit "$rc"
