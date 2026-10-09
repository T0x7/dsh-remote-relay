// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { injectRemoteGatingCss } from '../src/client/index.ts'
import { REMOTE_HIDDEN_NAV_SECTIONS } from '../src/remote-capability.ts'

const GATING_STYLE_ID = 'dsh-remote-gating'

function styling(): HTMLStyleElement | null {
  return document.getElementById(GATING_STYLE_ID) as HTMLStyleElement | null
}

function stubHostname(hostname: string): void {
  vi.stubGlobal('location', { hostname })
}

afterEach(() => {
  vi.unstubAllGlobals()
  styling()?.remove()
})

describe('remote gating CSS injection', () => {
  it('stays dormant on loopback origins (local dsh keeps full UI)', () => {
    for (const hostname of ['localhost', '127.0.0.1', '[::1]', '::1']) {
      styling()?.remove()
      stubHostname(hostname)
      injectRemoteGatingCss()
      expect(styling(), hostname).toBeNull()
    }
  })

  it('injects on non-loopback origins (relay channel) exactly once', () => {
    stubHostname('relay.example.com')
    injectRemoteGatingCss()
    injectRemoteGatingCss()
    const style = styling()
    expect(style).not.toBeNull()
    expect(document.querySelectorAll(`#${GATING_STYLE_ID}`)).toHaveLength(1)
  })

  it('hides the host.pickDirectory entries (workspace chooser buttons, zh+en)', () => {
    stubHostname('relay.example.com')
    injectRemoteGatingCss()
    const css = styling()!.textContent ?? ''
    for (const label of ['选择工作区', 'Choose workspace', '添加工作区', 'Add workspace']) {
      expect(css).toContain(`button[aria-label="${label}"]`)
    }
  })

  it('hides exactly the REMOTE_HIDDEN_NAV_SECTIONS nav items', () => {
    stubHostname('relay.example.com')
    injectRemoteGatingCss()
    const css = styling()!.textContent ?? ''
    const navRules = css.match(/\[class\$="_navList"\] > button:nth-child\((\d)\)/g) ?? []
    expect(navRules).toHaveLength(REMOTE_HIDDEN_NAV_SECTIONS.length)
    // Contract (see src/client/index.ts): nav items 2..4 are
    // models/plugins/agent-presets when the sys-schedule sections are present.
    expect(navRules).toEqual([
      '[class$="_navList"] > button:nth-child(2)',
      '[class$="_navList"] > button:nth-child(3)',
      '[class$="_navList"] > button:nth-child(4)',
    ])
  })
})
