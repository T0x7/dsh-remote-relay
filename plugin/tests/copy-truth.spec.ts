/**
 * v3.282: the card must not promise things the code does not do.
 *
 * Three shipped lies this pins out:
 *  - "所有已配对设备已失效" printed even when zero devices were paired;
 *  - "重新选择模式" referenced a mode selector deleted in v3.141;
 *  - the locale description said pairing tokens were "5 分钟有效、一次性"
 *    while the card mints 24-hour, re-usable pairings.
 *
 * Textual, like card-config-entry.spec.ts: these are copy contracts, and the
 * cheapest honest assertion on them is on the source itself.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const card = readFileSync(join(here, '../src/client/RemoteSettingsCard.tsx'), 'utf8')
const zhLocale = readFileSync(join(here, '../src/client/locales.ts'), 'utf8')
const enLocale = readFileSync(join(here, '../src/client/locales.en.ts'), 'utf8')

describe('v3.282 card copy matches behaviour', () => {
  it('「已配对设备已失效」only when devices exist; a clean state says 未连接', () => {
    expect(card).toContain("sessions.length > 0\n            ? '中继已断开，所有已配对设备已失效。")
    expect(card).toContain(": '中继未连接。点击下方「开启远程控制」生成配对二维码。'")
  })

  it('no reference to the mode selector removed in v3.141', () => {
    expect(card).not.toContain('重新选择模式')
  })

  it('no reference to the retired read-only remote page', () => {
    expect(card).not.toContain('远程只读页面')
  })

  it('the card heading is the locale title, not a second hardcoded name', () => {
    expect(card).toContain('<h3 style={{ margin: \'0 0 12px 0\' }}>{zh.title}</h3>')
    expect(card).not.toContain('公网远程控制 (Remote Relay)')
  })

  it('locales no longer claim 5-minute single-use pairing (reality: 24h QR)', () => {
    expect(zhLocale).not.toContain('5 分钟')
    expect(zhLocale).toContain('24 小时')
    expect(enLocale).not.toContain('5 minutes')
    expect(enLocale).toContain('24 hours')
  })
})
