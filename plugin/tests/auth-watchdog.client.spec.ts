// @vitest-environment jsdom
// v3.184：401 连击看门狗——凭证死亡后强制跳转 /__expired，不停留 dsh 壳。
import { afterEach, describe, expect, it, vi } from 'vitest'
import { installAuthFailureWatchdog, installDeviceReplacedWatchdog } from '../src/client/index.ts'

function stubLocation(hostname: string, href: string): ReturnType<typeof vi.fn> {
  const replace = vi.fn()
  // watchdog 比较 target.origin === globalThis.location.origin,href 同源判定
  // 依赖完整的 Location 字段(hostname/href/replace + origin)。
  const url = new URL(href)
  vi.stubGlobal('location', { hostname, href, replace, origin: url.origin, protocol: url.protocol, host: url.host })
  return replace
}

/** 状态序列回放 fetch——第 i 次调用返回 statuses[i]（越界取末值）。 */
function stubFetchByStatus(statuses: number[]): void {
  let i = 0
  const statusAt = (n: number): number => statuses[Math.min(n, statuses.length - 1)]!
  vi.stubGlobal('fetch', vi.fn(async (): Promise<Response> => ({ status: statusAt(i++) }) as Response))
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('auth-failure watchdog (v3.184)', () => {
  it('loopback（本机 dsh / 桌面 App）不安装——5 次 401 也不重定向', async () => {
    const replace = stubLocation('localhost', 'http://localhost:3000/')
    stubFetchByStatus([401])
    installAuthFailureWatchdog()
    for (let n = 0; n < 5; n++) await globalThis.fetch('/api/version')
    expect(replace).not.toHaveBeenCalled()
  })

  it('同源 /api 连续 3 次 401 → location.replace(/__expired) 恰一次', async () => {
    const replace = stubLocation('relay.test', 'https://relay.test/')
    stubFetchByStatus([401])
    installAuthFailureWatchdog()
    await globalThis.fetch('/api/version')        // 1
    await globalThis.fetch('/api/workspaces.list') // 2
    expect(replace).not.toHaveBeenCalled()
    await globalThis.fetch('/api/sessions.list')   // 3 → 触发
    expect(replace).toHaveBeenCalledTimes(1)
    expect(replace).toHaveBeenCalledWith('/__expired')
    await globalThis.fetch('/api/version')        // 已跳转——不重复
    expect(replace).toHaveBeenCalledTimes(1)
  })

  it('/dsh-remote/* 同样计数（数据面第二前缀）', async () => {
    const replace = stubLocation('relay.test', 'https://relay.test/')
    stubFetchByStatus([401])
    installAuthFailureWatchdog()
    await globalThis.fetch('/dsh-remote/session')
    await globalThis.fetch('/dsh-remote/session')
    await globalThis.fetch('/dsh-remote/session')
    expect(replace).toHaveBeenCalledTimes(1)
  })

  it('中间夹任一次成功响应即清零——401,401,200,401,401 不触发（relay 重启瞬态防误伤）', async () => {
    const replace = stubLocation('relay.test', 'https://relay.test/')
    stubFetchByStatus([401, 401, 200, 401, 401])
    installAuthFailureWatchdog()
    for (let n = 0; n < 5; n++) await globalThis.fetch('/api/version')
    expect(replace).not.toHaveBeenCalled()
    // 再来第 6 次 401 → 连击到 3 → 触发
    await globalThis.fetch('/api/version')
    expect(replace).toHaveBeenCalledTimes(1)
  })

  it('非数据面路径与跨源 401 不计数', async () => {
    const replace = stubLocation('relay.test', 'https://relay.test/')
    stubFetchByStatus([401])
    installAuthFailureWatchdog()
    for (let n = 0; n < 5; n++) await globalThis.fetch('/assets/app.js')
    for (let n = 0; n < 5; n++) await globalThis.fetch('https://elsewhere.example/api/version')
    expect(replace).not.toHaveBeenCalled()
  })

  it('卸载函数恢复原 fetch', async () => {
    const replace = stubLocation('relay.test', 'https://relay.test/')
    stubFetchByStatus([401])
    const originalFetch = globalThis.fetch
    const teardown = installAuthFailureWatchdog()
    expect(globalThis.fetch).not.toBe(originalFetch)
    teardown()
    expect(globalThis.fetch).toBe(originalFetch)
    expect(replace).not.toHaveBeenCalled()
  })
})

// v3.205：设备顶替看门狗——relay close(4001) 实时踢人，SPA 收码即跳专属页。
/** 可控假 WebSocket——测试手动派发 close 事件（不走真网络）。 */
class FakeWebSocket {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  readonly CONNECTING = 0
  readonly OPEN = 1
  readonly CLOSING = 2
  readonly CLOSED = 3
  readonly url: string
  private readonly listeners = new Map<string, Set<(ev: { code: number }) => void>>()
  constructor(url: string | URL) { this.url = String(url) }
  addEventListener(type: string, cb: (ev: { code: number }) => void): void {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set())
    this.listeners.get(type)!.add(cb)
  }
  emitClose(code: number): void {
    for (const cb of this.listeners.get('close') ?? []) cb({ code })
  }
}

describe('device-replaced watchdog (v3.205)', () => {
  function openWs(code: number): void {
    const ws = new (globalThis as unknown as { WebSocket: new (url: string) => FakeWebSocket }).WebSocket('/api/events.live')
    ws.emitClose(code)
  }

  it('loopback（本机 dsh / 桌面 App）不安装——close 4001 也不重定向', () => {
    const replace = stubLocation('localhost', 'http://localhost:3000/')
    vi.stubGlobal('WebSocket', FakeWebSocket)
    installDeviceReplacedWatchdog()
    openWs(4001)
    expect(replace).not.toHaveBeenCalled()
  })

  it('close 4001 → location.replace(/__expired?reason=replaced) 恰一次', () => {
    const replace = stubLocation('relay.test', 'https://relay.test/')
    vi.stubGlobal('WebSocket', FakeWebSocket)
    installDeviceReplacedWatchdog()
    openWs(4001)
    expect(replace).toHaveBeenCalledTimes(1)
    expect(replace).toHaveBeenCalledWith('/__expired?reason=replaced')
    openWs(4001) // 已跳转——不重复
    expect(replace).toHaveBeenCalledTimes(1)
  })

  it('其它 close 码（1000/1006/1012/4000）不触发——交给 dsh 自身重连', () => {
    const replace = stubLocation('relay.test', 'https://relay.test/')
    vi.stubGlobal('WebSocket', FakeWebSocket)
    installDeviceReplacedWatchdog()
    for (const code of [1000, 1006, 1012, 4000]) openWs(code)
    expect(replace).not.toHaveBeenCalled()
  })

  it('卸载函数恢复原 WebSocket', () => {
    stubLocation('relay.test', 'https://relay.test/')
    const original = FakeWebSocket
    vi.stubGlobal('WebSocket', FakeWebSocket)
    const teardown = installDeviceReplacedWatchdog()
    expect(globalThis.WebSocket).not.toBe(original)
    teardown()
    expect(globalThis.WebSocket).toBe(original)
  })
})
