/**
 * Relay-configuration value rules — pure, no dsh imports.
 *
 * The field specs and the secret-state reader are the parts of the settings
 * form that carry real logic, and they are kept free of any @deepseek-ai
 * import on purpose:
 *
 *  - the client half (src/client/index.ts) registers the card through these
 *    exports, so a dsh import here would drag the whole primitives package
 *    into every spec that loads the half (gating CSS, auth watchdogs);
 *  - relay-config-form.spec.ts can then exercise the real rules with no dsh
 *    checkout present, instead of stubbing them.
 *
 * The dsh wiring (SettingsFormModel over ctx.configForms.get, the
 * SettingsForm frame) lives in RelayConfigForm.tsx, which the host builds.
 */

/** The Host Loader row id declared in cordis.patch.yml — also the settings namespace. */
export const ENTRY_ID = 'dsh-remote'

/** This plugin's Host Config section as the browser sees it (secrets already redacted). */
export interface RelayConfigValues {
  enabled?: boolean
  relay_url?: string
  upstream_host?: string
  upstream_port?: number
}

/**
 * What one field's draft text stages, or undefined when the text is not a value
 * the field accepts — which blocks the save rather than discarding the edit.
 * Structurally the dsh `SettingsFieldWrite`; declared here so this module stays
 * import-free and the .tsx layer re-uses it verbatim.
 */
export type FieldWrite =
  | { kind: 'set'; value: unknown }
  | { kind: 'clear' }

/** How one Config field converts between its stored value and its draft text. */
export interface FieldSpec {
  field: string
  /** Render a stored value as draft text; the empty string when the section carries none. */
  format: (value: unknown) => string
  /** The write this draft stages, or undefined when the text is not acceptable. */
  parse: (text: string) => FieldWrite | undefined
}

/**
 * A boolean has no draft text of its own, so it is edited as the literal
 * `true` / `false` the Host stores. Anything else blocks the save instead of
 * being silently coerced into a truthy string.
 */
export function booleanField(field: string): FieldSpec {
  return {
    field,
    format: (value) => (value === true ? 'true' : value === false ? 'false' : ''),
    parse: (text) => {
      const trimmed = text.trim()
      if (trimmed === '') return { kind: 'clear' }
      if (trimmed === 'true') return { kind: 'set', value: true }
      if (trimmed === 'false') return { kind: 'set', value: false }
      return undefined
    },
  }
}

/** Free text: trimmed, and cleared when blank. */
export function textField(field: string): FieldSpec {
  return {
    field,
    format: (value) => (value === undefined || value === null ? '' : String(value)),
    parse: (text) => {
      const trimmed = text.trim()
      return trimmed === '' ? { kind: 'clear' } : { kind: 'set', value: trimmed }
    },
  }
}

/** A port: a bare integer in range, or an invalid draft that blocks the save. */
export function portField(field: string): FieldSpec {
  return {
    field,
    format: (value) => (typeof value === 'number' ? String(value) : ''),
    parse: (text) => {
      const trimmed = text.trim()
      if (trimmed === '') return { kind: 'clear' }
      const port = Number(trimmed)
      if (!Number.isInteger(port) || port < 1 || port > 65535) return undefined
      return { kind: 'set', value: port }
    },
  }
}

/** The section fields this card edits, in render order. */
export const RELAY_FIELD_SPECS: readonly FieldSpec[] = [
  booleanField('enabled'),
  textField('relay_url'),
  textField('upstream_host'),
  portField('upstream_port'),
]

/**
 * The write-only fields. `psk` and `engine_token` are `role('secret')` in the
 * Host schema: the Host strips them from every response, so the browser can
 * never read one back. Their drafts stay blank and a blank draft writes
 * nothing, so merely opening the form can never clear a stored secret.
 */
export const RELAY_SECRET_FIELDS: readonly string[] = ['psk', 'engine_token']

/** One secret slot as the Host reports it: the path, and whether it holds a value. */
export interface SecretSlot {
  /** Path from the section root to the redacted field. */
  path: string[]
  /** Whether the slot currently holds a value; the value itself never rides. */
  set: boolean
}

/**
 * Read one secret slot's configured flag. A secret's value never rides a
 * response — the Host reports only whether the slot holds one — so a control
 * can say "已设置" without ever echoing it.
 * @param secrets - this entry's secret slots, from the settings mirror.
 * @param field - the secret field name inside the section.
 * @returns whether the Host currently holds a value for that slot.
 */
export function secretConfigured(
  secrets: readonly SecretSlot[] | undefined,
  field: string,
): boolean {
  return secrets?.find((secret) => secret.path.join('.') === field)?.set === true
}
