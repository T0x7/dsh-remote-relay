#!/bin/bash
# Install the packed relay plugin INTO AN EXISTING dsh profile — the one a
# desktop app actually boots (`web` for dsh-host-app) — rather than into a
# throwaway test profile.
#
# WHY THIS EXISTS, given dev-test-profile.sh:
#   An app like dsh-host-app's engine launcher runs `node bin.js web` and nothing
#   else; it has no way to boot `dsh-remote-test`. A plugin verified only in the
#   test profile is therefore never exercised where it has to run. This installs
#   into the real profile, with a backup and an automatic rollback.
#
# WHY THE OVERRIDE IS MANDATORY:
#   The plugin tarball's manifest says `dsh-remote-relay-client: 1.0.0` (pnpm
#   rewrites `workspace:*` at pack time), and that name is on no registry until
#   the client is published. pnpm resolves that transitive edge against the
#   registry even when the same name is ALREADY a direct file: dependency in the
#   same package.json — verified on pnpm 10.28.1, both tarballs listed and still
#   ERR_PNPM_FETCH_404. Only an override keeps the edge off the registry.
#
# WHY bundles IS EDITED HERE:
#   Adding the plugin to `dependencies` alone is not enough. dsh turns a
#   dependency into a profile LAYER only when its name is in dsh.profile.bundles
#   (its plugin-manager does that reconciliation itself, but only for installs
#   IT runs — this script runs pnpm directly, so it does the edit itself).
#
# SAFETY:
#   Backs up package.json + pnpm-lock.yaml first; restores both and re-runs
#   pnpm install if the install fails. Nothing else in the profile is touched —
#   cordis.yml, cordis.patch.yml and the existing bundle list are left alone.
#
# usage: scripts/install-into-profile.sh [profile-name]   (default: web)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-web}"
PROFILE_DIR="$HOME/.dsh/profiles/$PROFILE"

case "$PROFILE" in
  ''|*[!a-zA-Z0-9_-]*)
    echo "install-into-profile: profile name must be letters, digits, '-' or '_' — got: '$PROFILE'" >&2
    exit 2
    ;;
esac

need() { [ -e "$1" ] || { echo "install-into-profile: missing $2" >&2; exit 2; }; }
need "$PROFILE_DIR" "profile '$PROFILE' ($PROFILE_DIR) — create it first, or use scripts/dev-test-profile.sh"
need "$PROFILE_DIR/package.json" "$PROFILE_DIR/package.json"

CLIENT_TGZ="$(ls "$ROOT"/dist-local/dsh-remote-relay-client-*.tgz 2>/dev/null | head -1)"
PLUGIN_TGZ="$(ls "$ROOT"/dist-local/dsh-remote-relay-plugin-*.tgz 2>/dev/null | head -1)"
[ -n "$CLIENT_TGZ" ] || { echo "install-into-profile: missing client tarball — run scripts/pack-local.sh first" >&2; exit 2; }
[ -n "$PLUGIN_TGZ" ] || { echo "install-into-profile: missing plugin tarball — run scripts/pack-local.sh first" >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_PKG="$PROFILE_DIR/package.json.bak-relay-$STAMP"
BACKUP_LOCK="$PROFILE_DIR/pnpm-lock.yaml.bak-relay-$STAMP"
cp "$PROFILE_DIR/package.json" "$BACKUP_PKG"
[ -e "$PROFILE_DIR/pnpm-lock.yaml" ] && cp "$PROFILE_DIR/pnpm-lock.yaml" "$BACKUP_LOCK"

echo "==> backing up"
echo "  $BACKUP_PKG"
[ -e "$BACKUP_LOCK" ] && echo "  $BACKUP_LOCK"

# Patch the manifest: two file: dependencies, the override that keeps the
# transitive name off the registry, and the bundle row that makes dsh treat the
# plugin as a profile layer. Idempotent — safe to re-run after a repack.
PATCH_JS="$PROFILE_DIR/.relay-install-patch.cjs"
cat > "$PATCH_JS" <<PATCH_EOF
const fs = require('node:fs')
const [file, clientTgz, pluginTgz, pluginName] = process.argv.slice(2)
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'))

manifest.dependencies ??= {}
manifest.dependencies[pluginName] = 'file:' + pluginTgz
manifest.dependencies['dsh-remote-relay-client'] = 'file:' + clientTgz

manifest.pnpm ??= {}
manifest.pnpm.overrides ??= {}
manifest.pnpm.overrides['dsh-remote-relay-client'] = 'file:' + clientTgz

manifest.dsh ??= {}
manifest.dsh.profile ??= {}
const bundles = (manifest.dsh.profile.bundles ??= [])
if (!bundles.includes(pluginName)) bundles.push(pluginName)

fs.writeFileSync(file, JSON.stringify(manifest, undefined, 2) + '\n')
console.log('  bundles:', bundles.length, '| dependencies:', Object.keys(manifest.dependencies).length)
PATCH_EOF

echo "==> patching $PROFILE_DIR/package.json"
node "$PATCH_JS" "$PROFILE_DIR/package.json" "$CLIENT_TGZ" "$PLUGIN_TGZ" dsh-remote-relay-plugin
rm -f "$PATCH_JS"

echo "==> pnpm install in $PROFILE_DIR"
if ! (cd "$PROFILE_DIR" && pnpm install); then
  echo >&2
  echo "install-into-profile: pnpm install FAILED — restoring the backup" >&2
  cp "$BACKUP_PKG" "$PROFILE_DIR/package.json"
  [ -e "$BACKUP_LOCK" ] && cp "$BACKUP_LOCK" "$PROFILE_DIR/pnpm-lock.yaml"
  (cd "$PROFILE_DIR" && pnpm install) || true
  echo "restored package.json + pnpm-lock.yaml; $PROFILE is back to its prior state" >&2
  exit 1
fi

cat <<DONE

installed into profile: $PROFILE
  client tarball: $CLIENT_TGZ
  plugin tarball: $PLUGIN_TGZ

backup: $BACKUP_PKG

restart the app (or re-run its engine) so the new bundle layer is picked up,
then open Plugins → 远程控制 (dsh-remote-relay-plugin) → 配置 and fill
中继地址 / 共享密钥, then flip 启用出站中继隧道 on.

to undo:
  cp '$BACKUP_PKG' '$PROFILE_DIR/package.json'
  [ -e '$BACKUP_LOCK' ] && cp '$BACKUP_LOCK' '$PROFILE_DIR/pnpm-lock.yaml'
  (cd '$PROFILE_DIR' && pnpm install)

NOTE: if this app ever re-seeds the profile from its own profile template, the
pnpm.overrides entry is lost and the install fails again with
ERR_PNPM_FETCH_404 on dsh-remote-relay-client. Re-run this script then.
DONE
