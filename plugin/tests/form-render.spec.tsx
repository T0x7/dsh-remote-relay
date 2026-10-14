// @vitest-environment jsdom
/**
 * The one test that would have caught the swallowed-keystroke bug.
 *
 * History, so this never gets "simplified" away: RelayConfigForm used to read
 * `model.shell()` / `model.field()` directly from render without subscribing.
 * A keystroke mutated the model but triggered no re-render, React reset the
 * controlled input to its last-rendered text, and the typed character
 * reappeared only when the parent's one-second tick repainted the subtree.
 * Every existing spec was blind to it because vitest.config.ts aliases the
 * .tsx card modules to stubs — the config file itself documents that the
 * stubs "blind every spec in this run to the card↔form↔mount glue".
 *
 * This suite renders the REAL component against the REAL SettingsFormModel
 * (which needs no dsh runtime — that was the point of keeping
 * relay-config-model.ts import-free) and asserts the controlled-input echo:
 * type → the input shows the character on the same tick, synchronously, with
 * no timer in between.
 */
import { describe, expect, it } from 'vitest'
import React, { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { SettingsFormModel } from '@deepseek-ai/dsh-client-ui-primitives'
import { RelayConfigForm } from '../src/client/RelayConfigForm.tsx'
import { RELAY_FIELD_SPECS, type RelayConfigValues } from '../src/client/relay-config-model.ts'

/**
 * A ConfigForm double carrying the semantics the model relies on: read the
 * section, set one field, fence writes by revision. Small, but honest — a
 * looser double here would be the exact "fake greener than production" trap
 * this file exists to close.
 */
function fakeConfigForm(initial: Partial<RelayConfigValues> = {}) {
  let section: Record<string, unknown> = { ...initial }
  let revision = 1
  const listeners = new Set<() => void>()
  return {
    getSnapshot: () => ({
      status: 'ready' as const,
      value: section as RelayConfigValues,
      base: {},
      user: section,
      revision,
      writable: true,
      mode: 'host' as const,
    }),
    subscribe: (fn: () => void) => {
      listeners.add(fn)
      return () => { listeners.delete(fn) }
    },
    mutate: async (ops: Array<{ op: string; path: string[]; value?: unknown }>) => {
      for (const op of ops) {
        if (op.op === 'set') section[op.path[0] as string] = op.value
        if (op.op === 'unset') delete section[op.path[0] as string]
      }
      revision += 1
      for (const fn of listeners) fn()
      return true
    },
    set: async (field: string, value: unknown) => {
      section[field] = value
      revision += 1
      for (const fn of listeners) fn()
      return true
    },
  }
}

function mountForm() {
  const host = document.createElement('div')
  document.body.appendChild(host)
  const root: Root = createRoot(host)
  const model = new SettingsFormModel<RelayConfigValues>(
    fakeConfigForm({
      enabled: false,
      relay_url: 'http://127.0.0.1:8080',
      upstream_host: '127.0.0.1',
      upstream_port: 3080,
    }) as unknown as ConstructorParameters<typeof SettingsFormModel<RelayConfigValues>>[0],
    [...RELAY_FIELD_SPECS],
  )
  act(() => {
    root.render(React.createElement(RelayConfigForm, { model, secrets: [] }))
  })
  if (process.env.RENDER_DEBUG) console.log('RENDERED:', host.innerHTML.slice(0, 1200))
  return { root, host, model }
}

const inputByd = (host: HTMLElement, id: string): HTMLInputElement =>
  host.querySelector(`#${id}`) as HTMLInputElement

/** Fire a change event on the input the way React's onChange expects it. */
function change(input: HTMLInputElement, value: string): void {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!
  setter.call(input, value)
  input.dispatchEvent(new Event('change', { bubbles: true }))
  input.dispatchEvent(new Event('input', { bubbles: true }))
}

describe('RelayConfigForm renders as a subscribed controlled form (v3.282)', () => {
  it('a typed character appears in the input on the SAME tick — no timer, no lost keystroke', () => {
    const { root, host } = mountForm()
    const input = inputByd(host, 'plugin-config-remote-relay-url')
    expect(input.value).toBe('http://127.0.0.1:8080')

    // The regression: this fireEvent changed the model but the DOM kept the
    // old text until some other render happened. Same-tick echo is the contract.
    act(() => { change(input, 'http://127.0.0.1:8080X') })
    expect(input.value).toBe('http://127.0.0.1:8080X')

    // And the field after it composes normally (draft survives, not reset).
    act(() => { change(input, 'http://relay.example.com') })
    expect(input.value).toBe('http://relay.example.com')
    root.unmount()
    host.remove()
  })

  it('the save button enables the moment a draft exists (not one repaint late)', () => {
    const { root, host } = mountForm()
    const input = inputByd(host, 'plugin-config-remote-relay-url')
    const save = Array.from(host.querySelectorAll('button')).find((b) => b.textContent === '保存')
    expect(save).toBeTruthy()
    expect(save!.disabled).toBe(true)

    act(() => { change(input, 'https://relay.example.com') })
    expect(save!.disabled).toBe(false)
    root.unmount()
    host.remove()
  })

  it('an invalid draft is reported immediately (aria-invalid without any tick)', () => {
    const { root, host } = mountForm()
    const port = inputByd(host, 'plugin-config-remote-upstream-port')
    act(() => { change(port, 'not-a-port') })
    expect(port.getAttribute('aria-invalid')).toBe('true')
    act(() => { change(port, '99999') })
    expect(port.getAttribute('aria-invalid')).toBe('true') // out of range still invalid
    act(() => { change(port, '8080') })
    expect(port.getAttribute('aria-invalid')).toBeNull()
    root.unmount()
    host.remove()
  })
})
