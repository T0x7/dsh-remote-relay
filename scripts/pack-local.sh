#!/bin/bash
# Pack local, installable tarballs for testing the plugin on a real dsh
# WITHOUT publishing to npm:
#
#   dist-local/dsh-remote-relay-client-<v>.tgz
#   dist-local/dsh-remote-relay-plugin-<v>.tgz
#   dist-local/dsh-remote-relay-<v>.tgz        (server — for VPS deploys by tgz)
#
# Why both client and plugin: the plugin's dependency on
# `dsh-remote-relay-client` is `workspace:*` inside this repo, which pnpm
# rewrites to a plain version at pack time. That means the plugin tarball asks
# for `dsh-remote-relay-client@<version>` BY NAME — and until that name exists
# on npm, pnpm will try to fetch that name from the registry no matter what
# else the consuming profile lists. Shipping the client tarball alongside is
# necessary but NOT sufficient: a pnpm.overrides entry pinning the name to that
# same tarball is what actually keeps the edge off the registry. Both live in
# scripts/dev-test-profile.sh, which is the supported install path.
#
# Prerequisites: `pnpm install` and `pnpm -r build` at the repo root (pack also
# re-runs the plugin's `prepare`, which rebuilds — devDependencies must be
# installed or `workspace:*` cannot be rewritten at all).
#
# usage: scripts/pack-local.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist-local"
cd "$ROOT" || exit 1

need() { [ -e "$1" ] || { echo "pack-local: missing $1 — run 'pnpm install && pnpm -r build' at the repo root first" >&2; exit 2; }; }
need client/node_modules
need plugin/node_modules
need client/dist/index.js
need plugin/lib/index.js
need plugin/lib/client.js

mkdir -p "$OUT"
rm -f "$OUT"/*.tgz

for pkg in client plugin server; do
  echo "==> pnpm pack $pkg"
  (cd "$pkg" && pnpm pack --pack-destination "$OUT" >/dev/null)
done

CLIENT_TGZ=$(ls "$OUT"/dsh-remote-relay-client-*.tgz)
PLUGIN_TGZ=$(ls "$OUT"/dsh-remote-relay-plugin-*.tgz)
SERVER_TGZ=$(ls "$OUT"/dsh-remote-relay-*.tgz | grep -v client | grep -v plugin)

echo
echo "packed:"
echo "  $CLIENT_TGZ"
echo "  $PLUGIN_TGZ"
echo "  $SERVER_TGZ"
echo
echo "install into a dsh profile: use the dedicated pre-publish test profile."
echo "Do NOT 'dsh plugin add' the tarballs into a live profile — see below."
echo
echo "  scripts/dev-test-profile.sh [profile-name]   # default: dsh-remote-test"
echo
echo "That script authors the profile with both tarballs as file: dependencies"
echo "PLUS the pnpm.overrides entry below, then runs pnpm install there."
echo
echo "WHY the override is mandatory, not a fallback: pnpm resolves the plugin's"
echo "dependency edge 'dsh-remote-relay-client@<version>' against the registry"
echo "even when the same name is already a direct file: dependency in the same"
echo "package.json. Verified on pnpm 10.28.1 — a profile whose dependencies list"
echo "BOTH tarballs still fails with ERR_PNPM_FETCH_404 on the client name."
echo "An override is the only thing that keeps that edge off the registry:"
echo
echo '  "pnpm": {'
echo "    \"overrides\": { \"dsh-remote-relay-client\": \"file:$CLIENT_TGZ\" }"
echo '  }'
echo
echo "Once the client is published to npm this stops mattering: the rewritten"
echo "version resolves by name and no override is needed."
echo
echo "after install: Plugins → 远程控制 (dsh-remote-relay-plugin) → 配置 —"
echo "fill 中继地址 / 共享密钥 (the relay's RELAY_PSK; docs/deploy.md §2 for"
echo "where to read it back), then flip 启用出站中继隧道 on."
