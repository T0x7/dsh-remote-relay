/**
 * Drift guard for PRIVILEGED_METHODS_MIRROR (src/remote-capability.ts).
 *
 * HISTORY (kept deliberately — it is the reason this file is self-contained):
 * the original suite in the dsh monorepo mounted dsh's connection plugin and
 * text-pinned its PRIVILEGED_METHODS Set literal, i.e. it could only run
 * inside a dsh checkout. Since dsh 0.1.7 the upstream fence moved from a
 * per-method PRIVILEGED_METHODS set to a whole-host trustedHosts trust
 * barrier, so that literal no longer exists and both probes were `it.skip` —
 * a green-but-dead guard. Leaving them skipped would silently stop guarding
 * anything once this package left the monorepo.
 *
 * What this file does instead, so the mirror stays honest standalone:
 *   1. The mirror's own shape is pinned: 16 entries, four threat classes,
 *      each with the "why" rationale preserved per member.
 *   2. Members that must stay closed remain closed; the deliberately-open
 *      ones (documented negative space) are asserted absent, so widening
 *      the fence shows up as a diff instead of a silent security loosening.
 *
 * When a future dsh reintroduces an explicit privileged-method set, add a
 * probe here that reads it from the installed @deepseek-ai/dsh-* package.
 */
import { describe, expect, it } from 'vitest'
import {
  PRIVILEGED_METHODS_MIRROR,
  isPrivilegedMethod,
} from '../src/remote-capability.ts'

/**
 * Deliberately open remotely (dsh source's own reverse argument, retained
 * in the ADR): no endpoint or key, so a LAN/relay client legitimately
 * needs them; blocking preset selection while `session.create` already
 * accepts a preset would be "a fence bolted beside an open door".
 */
const DELIBERATELY_OPEN = [
  'llm.providers',
  'llm.models',
  'agentPreset.list',
  'session.create',
  'session.prompt',
]

describe('privileged mirror stays aligned with the remote trust model', () => {
  it('pins the mirror size — dsh added/removed a privileged method', () => {
    expect(PRIVILEGED_METHODS_MIRROR.size).toBe(16)
  })

  it('pins the four threat classes end to end', () => {
    const groups: Record<string, string[]> = {
      // Config surface: settings.describe returns every namespace — recon.
      config: ['settings.describe', 'settings.update', 'settings.replace', 'settings.mutate', 'settings.openDocument'],
      // Credential surface: credentials.describe probes env var names.
      credentials: ['credentials.describe', 'credentials.set', 'credentials.unset'],
      // Host desktop: drives native dialogs on the engine's machine.
      host: ['host.pickDirectory', 'host.openPath', 'agentPreset.openDocument'],
      // Recon / SSRF: discoverModels makes the HOST fetch a caller-chosen URL.
      recon: ['agentPreset.read', 'agentPreset.copy', 'agentPreset.remove', 'llm.discoverModels'],
      // Subprocess-only: its only legal consumer is a loopback agent process.
      subprocess: ['tool.invoke'],
    }
    const all = Object.values(groups).flat()
    expect(new Set(all).size).toBe(all.length)
    for (const method of all) {
      expect(isPrivilegedMethod(method), `${method} must stay privileged`).toBe(true)
    }
    // Every mirror member is classified — an unclassified addition is a
    // silent security change and must fail here.
    expect([...PRIVILEGED_METHODS_MIRROR].sort()).toEqual([...all].sort())
  })

  it('keeps the deliberately-open methods out of the mirror', () => {
    for (const method of DELIBERATELY_OPEN) {
      expect(isPrivilegedMethod(method), `${method} is open by design`).toBe(false)
    }
  })

  it('rejects unknown and near-miss method names', () => {
    expect(isPrivilegedMethod('settings.describe ')).toBe(false)
    expect(isPrivilegedMethod('Settings.Describe')).toBe(false)
    expect(isPrivilegedMethod('session.list')).toBe(false)
  })
})
