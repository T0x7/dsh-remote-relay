#!/bin/bash
# Create (or refresh) a dedicated dsh profile installed from the LOCAL
# tarballs — the pre-publish test environment.
#
# Why a dedicated profile: your existing profiles are production. And why
# this script exists at all: the plugin tarball depends on
# `dsh-remote-relay-client` BY NAME (workspace:* is rewritten at pack time),
# and that name is not on any registry until the client is published — a
# plain `dsh plugin add` therefore 404s. Authoring the profile directly,
# with both tarballs as file: dependencies plus an override pinning the
# transitive name to the same local tarball, sidesteps the registry
# entirely and needs no build permission.
#
# usage: scripts/dev-test-profile.sh [profile-name]   (default dsh-remote-test)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-dsh-remote-test}"
PROFILE_DIR="$HOME/.dsh/profiles/$PROFILE"

# A profile name becomes a directory name AND (as "dsh-profile-<name>") an npm
# package name, so it has to be a plain identifier. Refuse anything else rather
# than cheerfully creating a profile nobody can boot by name. The common way to
# land here is pasting this command together with a trailing `# comment`: the
# shell passes the `#` through as $1 and a profile literally named "#" appears.
case "$PROFILE" in
  ''|*[!a-zA-Z0-9_-]*)
    echo "dev-test-profile: profile name must be letters, digits, '-' or '_' — got: '$PROFILE'" >&2
    echo "  if you pasted a '# comment' onto the command line, drop it or run the command on its own" >&2
    exit 2
    ;;
esac

CLIENT_TGZ="$(ls "$ROOT"/dist-local/dsh-remote-relay-client-*.tgz 2>/dev/null | head -1)"
PLUGIN_TGZ="$(ls "$ROOT"/dist-local/dsh-remote-relay-plugin-*.tgz 2>/dev/null | head -1)"
if [ -z "$CLIENT_TGZ" ] || [ -z "$PLUGIN_TGZ" ]; then
  echo "dev-test-profile: missing tarballs under dist-local/ — run scripts/pack-local.sh first" >&2
  exit 2
fi

mkdir -p "$PROFILE_DIR"

cat > "$PROFILE_DIR/package.json" <<EOF
{
  "name": "dsh-profile-$PROFILE",
  "private": true,
  "dependencies": {
    "dsh-remote-relay-client": "file:$CLIENT_TGZ",
    "dsh-remote-relay-plugin": "file:$PLUGIN_TGZ"
  },
  "pnpm": {
    "overrides": {
      "dsh-remote-relay-client": "file:$CLIENT_TGZ"
    }
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "dsh-remote-relay-plugin"
      ]
    }
  }
}
EOF

# Mirror the shape dsh itself writes (nodeLinker hoisted, peers resolved by
# the base bundle at boot rather than auto-installed).
cat > "$PROFILE_DIR/pnpm-workspace.yaml" <<'EOF'
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
EOF

# Profile root layer: empty entry list — the bundles supply every row.
printf '[]\n' > "$PROFILE_DIR/cordis.yml"

echo "==> installing into $PROFILE_DIR"
(cd "$PROFILE_DIR" && pnpm install)

cat <<DONE

profile ready: $PROFILE
  client tarball: $CLIENT_TGZ
  plugin tarball: $PLUGIN_TGZ

boot it with:

  dsh --profile $PROFILE

(stop any running dsh first if ports clash). In the UI open
Plugins → 远程控制 (dsh-remote-relay-plugin) → 配置 and fill
中继地址 / 共享密钥, then flip 启用出站中继隧道 on.
DONE
