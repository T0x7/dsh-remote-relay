/**
 * Contract spec for the config-entry wiring — card condition, form props,
 * and which surface carries the form.
 *
 * WHY THIS EXISTS AS A SOURCE-LEVEL SPEC: every spec that imports
 * src/client/index.ts gets the card and the form view aliased to stubs
 * (see vitest.config.ts), so the glue between them has no execution path in
 * this suite — and that is exactly how a real bug shipped: the card's render
 * condition demanded a `describe` prop that no caller passed (and the form
 * wanted `secrets` anyway), so the configuration entry silently rendered on
 * NO surface. `pnpm typecheck` rejects the prop mismatch on a full install;
 * this spec pins the same three seams textually so the regression is caught
 * even in a bare checkout, where nothing else can see it.
 *
 * The seams, and what a break here means:
 *   1. RemoteSettingsCard renders RelayConfigForm iff `relayForm` is present,
 *      passing `secrets` — the only props RelayConfigForm accepts.
 *   2. The form view's props are { model, secrets } — a `describe` prop has
 *      never existed on it.
 *   3. index.ts wires the form model ONLY into the Plugins-page card
 *      (ConfigCard); the Settings-section card (StatusCard) renders bare, so
 *      no configuration entry appears outside the plugin's own page.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'client')
const card = readFileSync(join(root, 'RemoteSettingsCard.tsx'), 'utf8')
const form = readFileSync(join(root, 'RelayConfigForm.tsx'), 'utf8')
const entry = readFileSync(join(root, 'index.ts'), 'utf8')
const locales = readFileSync(join(root, 'locales.ts'), 'utf8')
const localesEn = readFileSync(join(root, 'locales.en.ts'), 'utf8')

describe('config-entry wiring (card ↔ form ↔ mounts)', () => {
  it('the card renders the form exactly when a form model is passed', () => {
    // Not `relayForm && describe` — that condition is the shipped bug: no
    // caller ever passed `describe`, so the form rendered nowhere.
    expect(card).toMatch(/\{\s*props\?\.relayForm \?/)
    expect(card).not.toMatch(/props\?\.relayForm && props\.describe/)
  })

  it('the card hands the form its model and the secret slots, nothing else', () => {
    expect(card).toMatch(/<RelayConfigForm model=\{props\.relayForm\} secrets=\{props\.secrets\}/)
  })

  it('the form view accepts { model, secrets } — a describe prop has never existed', () => {
    expect(form).toMatch(/export function RelayConfigForm\(props:\s*\{\s*model:/)
    expect(form).toMatch(/secrets: readonly SecretSlot\[\] \| undefined/)
    expect(form).not.toMatch(/describe/)
  })

  it('the card declares the secrets prop it forwards', () => {
    expect(card).toMatch(/secrets\?: readonly SecretSlot\[\] \| undefined/)
  })

  it('createRelayForm is imported from the form module that exports it', () => {
    // The build caught this seam broken: index.ts imported createRelayForm
    // from relay-config-model.ts, which never exported it (it lives in
    // RelayConfigForm.tsx, which new()s a ui-primitives class). tsc's host
    // build never compiles the client half and vitest stubs the tsx modules,
    // so only the real bundler saw it.
    expect(entry).toMatch(/import \{ createRelayForm \} from '\.\/RelayConfigForm\.tsx'/)
    expect(form).toMatch(/export function createRelayForm\(/)
    const model = readFileSync(join(root, 'relay-config-model.ts'), 'utf8')
    expect(model).not.toMatch(/export function createRelayForm/)
  })

  it('configuration lives ONLY on the Plugins detail page (no settings.nav entry)', () => {
    // One configuration home: the bundle detail page in the Plugins panel
    // (ConfigCard — form + QR + devices). The former Settings-nav section is
    // gone, so the relay address and PSK are never reachable from a second
    // surface; a paired phone has no card at all.
    const configCard = entry.match(/const ConfigCard[\s\S]*?\n\s*ctx\.slots\.inject\('plugins\.bundle\.config'/)
    expect(configCard).not.toBeNull()
    expect(configCard![0]).toMatch(/relayForm, secrets: secretSlots\(\)/)

    expect(entry).not.toMatch(/ctx\.slots\.inject\('settings\.section'/)
    expect(entry).not.toMatch(/const StatusCard/)
    // The 'nav' dictionary key existed only for that section's label.
    for (const dictionary of [locales, localesEn]) {
      expect(dictionary).not.toMatch(/\bnav:/)
    }
  })
})
