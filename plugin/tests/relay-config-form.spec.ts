/**
 * Relay-configuration value rules.
 *
 * The field specs are where a silent data bug would live: a port stored as a
 * string, a boolean coerced to a truthy string, a trailing space kept in a
 * URL, an out-of-range port silently accepted. They are deliberately free of
 * any dsh import, so these specs run against the real shipped logic with no
 * dsh checkout present. The dsh wiring (SettingsFormModel over
 * ctx.configForms.get, the SettingsForm frame) lives in RelayConfigForm.tsx
 * and is exercised by the dsh host at install time.
 */
import { describe, expect, it } from 'vitest'
import {
  ENTRY_ID,
  RELAY_FIELD_SPECS,
  RELAY_SECRET_FIELDS,
  booleanField,
  portField,
  secretConfigured,
  textField,
} from '../src/client/relay-config-model.ts'

const spec = (field: string) => {
  const found = RELAY_FIELD_SPECS.find((candidate) => candidate.field === field)
  if (!found) throw new Error(`no spec for ${field}`)
  return found
}

describe('relay config form — value rules', () => {
  it('targets the Host Loader row id, which is also the settings namespace', () => {
    expect(ENTRY_ID).toBe('dsh-remote')
  })

  it('covers exactly the editable section fields', () => {
    expect(RELAY_FIELD_SPECS.map((field) => field.field)).toEqual([
      'enabled', 'relay_url', 'upstream_host', 'upstream_port',
    ])
  })

  it('declares the two write-only secret fields', () => {
    expect([...RELAY_SECRET_FIELDS]).toEqual(['psk', 'engine_token'])
  })
})

describe('boolean field (enabled)', () => {
  it('formats stored booleans as the literals the Host stores', () => {
    const field = booleanField('enabled')
    expect(field.format(true)).toBe('true')
    expect(field.format(false)).toBe('false')
    expect(field.format(undefined)).toBe('')
  })

  it('accepts true / false and clears on empty', () => {
    const field = booleanField('enabled')
    expect(field.parse('true')).toEqual({ kind: 'set', value: true })
    expect(field.parse('false')).toEqual({ kind: 'set', value: false })
    expect(field.parse('  ')).toEqual({ kind: 'clear' })
  })

  it('rejects anything else so the save is blocked, never coerced', () => {
    const field = booleanField('enabled')
    for (const bad of ['yes', '1', 'TRUE', 'on']) {
      expect(field.parse(bad)).toBeUndefined()
    }
  })

  it('round-trips through format/parse without drift', () => {
    const field = spec('enabled')
    expect(field.parse(field.format(true))).toEqual({ kind: 'set', value: true })
    expect(field.parse(field.format(false))).toEqual({ kind: 'set', value: false })
  })
})

describe('port field (upstream_port)', () => {
  it('formats a stored number and nothing else', () => {
    const field = portField('upstream_port')
    expect(field.format(3080)).toBe('3080')
    expect(field.format('3080')).toBe('')
    expect(field.format(undefined)).toBe('')
  })

  it('accepts an in-range integer and clears on empty', () => {
    const field = portField('upstream_port')
    expect(field.parse('1')).toEqual({ kind: 'set', value: 1 })
    expect(field.parse('65535')).toEqual({ kind: 'set', value: 65535 })
    expect(field.parse(' 3080 ')).toEqual({ kind: 'set', value: 3080 })
    expect(field.parse('')).toEqual({ kind: 'clear' })
  })

  it('blocks the save for out-of-range and non-integer ports', () => {
    const field = portField('upstream_port')
    for (const bad of ['0', '65536', '-1', '30.5', 'abc', '8080abc']) {
      expect(field.parse(bad)).toBeUndefined()
    }
  })
})

describe('text fields (relay_url, upstream_host)', () => {
  it('trims the staged value, so a pasted URL keeps no stray whitespace', () => {
    const field = textField('relay_url')
    expect(field.parse('  https://relay.example.com  ')).toEqual({
      kind: 'set', value: 'https://relay.example.com',
    })
  })

  it('clears on whitespace-only input', () => {
    expect(textField('relay_url').parse('   ')).toEqual({ kind: 'clear' })
  })

  it('formats an absent value as an empty draft', () => {
    expect(textField('relay_url').format(undefined)).toBe('')
    expect(textField('relay_url').format('127.0.0.1')).toBe('127.0.0.1')
  })
})

describe('secret state (psk, engine_token)', () => {
  it('reports a configured slot without ever reading a value', () => {
    const slots = [
      { path: ['psk'], set: true },
      { path: ['engine_token'], set: false },
    ]
    expect(secretConfigured(slots, 'psk')).toBe(true)
    expect(secretConfigured(slots, 'engine_token')).toBe(false)
  })

  it('is false when the Host served no secret slots at all', () => {
    expect(secretConfigured(undefined, 'psk')).toBe(false)
    expect(secretConfigured([], 'psk')).toBe(false)
  })

  it('matches a nested path rather than a bare name', () => {
    expect(secretConfigured([{ path: ['nested', 'psk'], set: true }], 'psk')).toBe(false)
  })
})
