/**
 * Remote capability contract: a mirror of dsh's loopback-only
 * PRIVILEGED_METHODS fence (client/connection/src/index.ts). The authority
 * stays in dsh core — this file exists so the plugin's docs, gating CSS and
 * tests consume one named thing instead of re-quoting the fence. Alignment
 * with the authority is enforced by tests/privileged-alignment.spec.ts
 * (behavioral 403 probe plus a source-text pin); when dsh adds or removes a
 * method, that test turns red and this mirror must be updated in the same
 * change — the same hand-copy-with-review discipline as the relay protocol
 * types (M01 decision #4).
 */

export const PRIVILEGED_METHODS_MIRROR: ReadonlySet<string> = new Set([
  // A preset composition names the plugins a session runs: reading one is
  // reconnaissance, copy/remove manage the roster, openDocument drives the
  // host desktop. Choosing a preset and listing them stay open (dsh source
  // argues session.create already carries the same capability).
  'agentPreset.read',
  'agentPreset.copy',
  'agentPreset.openDocument',
  'agentPreset.remove',
  // Native dialogs act on the host machine's desktop.
  'host.pickDirectory',
  'host.openPath',
  // The configuration plane, reads included: settings.describe returns every
  // exposed namespace's configuration to any caller.
  'settings.describe',
  'settings.openDocument',
  'settings.update',
  'settings.replace',
  'settings.mutate',
  // The secret store: credentials.describe reveals whether an arbitrary
  // environment-variable name is configured and where from.
  'credentials.describe',
  'credentials.set',
  'credentials.unset',
  // Carries a draft credential AND makes the host issue a GET to a
  // caller-chosen URL — an SSRF probe for whatever the host can reach.
  'llm.discoverModels',
  // Loopback-only by intent, not privilege: the engine's own loopback
  // subprocess on
  // 127.0.0.1 is the only intended consumer (added 2026-08-21).
  'tool.invoke',
])

/**
 * Settings sections whose nav entries the remote gating CSS hides (see
 * src/client/index.ts REMOTE_GATING_CSS). Schedule/realtime plugin sections
 * stay visible remotely by decision: they serve plain plugin HTTP routes with
 * no PRIVILEGED /api surface, and remote timer control is a core remote-use
 * value.
 */
export const REMOTE_HIDDEN_NAV_SECTIONS = ['models', 'plugins', 'agent-presets'] as const

export function isPrivilegedMethod(method: string): boolean {
  return PRIVILEGED_METHODS_MIRROR.has(method)
}
