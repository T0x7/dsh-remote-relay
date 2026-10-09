// Node env — spins a real ws server as the relay's /ws/dsh stand-in and pins
// the session.register payload shape (protocol types are hand-copied between
// client and relay; tests keep them aligned).
//
// v3.141：单模式化——删除 v3.106 加的 mode 字段相关断言；session.register
// payload 不再带 mode，createSession() 不带参。
import { afterEach, describe, expect, it, vi } from 'vitest'
import { WebSocketServer, type WebSocket as WsServerSocket } from 'ws'
import { RemoteTunnelClient, type RemoteSessionInfo } from '../src/tunnel.ts'

interface ReceivedMessage {
  type: string
  payload: { sessionId: string; pairingToken: string; ttlSeconds: number; engineToken?: string }
}

describe('RemoteTunnelClient pairing + tunnel plumbing', () => {
  let wss: WebSocketServer | null = null
  let client: RemoteTunnelClient | null = null

  afterEach(() => {
    client?.disconnect()
    client = null
    wss?.close()
    wss = null
  })

  async function spinRelay(messages: ReceivedMessage[]): Promise<{ client: RemoteTunnelClient }> {
    wss = new WebSocketServer({ port: 0 })
    const port = (wss.address() as { port: number }).port
    wss.on('connection', (socket: WsServerSocket) => {
      socket.on('message', (raw) => messages.push(JSON.parse(raw.toString())))
    })
    client = new RemoteTunnelClient({
      enabled: true,
      relayUrl: `http://127.0.0.1:${port}`,
      psk: 'test-psk',
    }, { persist: false })
    client.connect(true)
    await new Promise<void>((resolve) => wss!.once('connection', () => resolve()))
    // Let the client's 'open' handler settle so createSession() sees OPEN.
    await new Promise((resolve) => setTimeout(resolve, 100))
    return { client }
  }

  it('createSession() → session.register payload 不带 mode 字段（v3.141 单模式化）', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)

    const info = c.createSession()
    // info 没有 mode 字段
    expect((info as unknown as { mode?: string }).mode).toBeUndefined()

    await vi.waitFor(() => expect(received.length).toBeGreaterThan(0))
    const register = received.find((m) => m.type === 'session.register')
    expect(register).toBeDefined()
    expect(register!.payload.sessionId).toBe(info.sessionId)
    expect(register!.payload.pairingToken).toBe(info.pairingToken)
    expect(register!.payload.ttlSeconds).toBe(300)
    expect(register!.payload.mode).toBeUndefined()
  })

  it('qrUrl 走根路径 URL 会话格式(v3.176.2:/?sessionId&hash&t&exp&mid,无 token,不再 /__pair)', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)
    const info = c.createSession()
    const u = new URL(info.qrUrl)
    // 根路径(不是 /__pair)——扫码打开 = URL 会话,SPA 注入 Bearer,不颁 cookie
    expect(u.pathname).toBe('/')
    expect(u.searchParams.get('sessionId')).toBe(info.sessionId)
    // v3.176.2:不得带 token——dsh authorizeIndex 对 query 含 token 的 / 一律
    // 303 剥 query,SPA 落地即失凭证(卡 connecting 的根因)
    expect(u.searchParams.has('token')).toBe(false)
    expect(u.searchParams.get('hash')).toMatch(/^[A-Za-z0-9_-]{43}$/)
    expect(u.searchParams.get('t')).toMatch(/^[0-9]{1,20}$/)
    expect(u.searchParams.get('exp')).toMatch(/^[0-9]{1,20}$/)
    expect(u.searchParams.get('mid')).toMatch(/^[a-f0-9]{64}$/)
    // QR 窗口与 URL TTL 对齐(24h),卡片倒计时如实反映链接寿命
    expect(info.expiresAt - Number(u.searchParams.get('t'))).toBe(24 * 3600 * 1000)
  })

  it('session.register carries engineToken from DSH_BIND_TOKEN (v3.41 lockdown 注入，随引擎启动轮换)', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)
    vi.stubEnv('DSH_BIND_TOKEN', 'engine-secret-abc123')
    try {
      c.createSession()
      await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(1))
      expect(received[0]!.payload.engineToken).toBe('engine-secret-abc123')
    } finally {
      vi.unstubAllEnvs()
    }
  })

  it('tunnel reconnect re-registers the retained pairing with the SAME sessionId+token (relay grace rebinds the original cookie secret)', async () => {
    const received: ReceivedMessage[] = []
    // 数据根隔离：本用例必须开着持久化（重连后重注册要把配对从盘上读回来），
    // 若沿用默认 ~/.dsh-remote-relay，测试会收养本机真实配对、把
    // session.register 数量顶到 3，还会把本用例的会话写进真实存储
    // （2026-10-02 真实配对存在时该用例即失败）。
    const os = await import('node:os')
    const fsMod = await import('node:fs')
    const tmpRoot = fsMod.mkdtempSync(os.tmpdir() + '/remote-reconnect-test-')
    const previousRoot = process.env.DSH_REMOTE_DATA_ROOT
    process.env.DSH_REMOTE_DATA_ROOT = tmpRoot
    wss = new WebSocketServer({ port: 0 })
    const relayPort = (wss.address() as { port: number }).port
    wss.on('connection', (socket: WsServerSocket) => {
      socket.on('message', (raw) => received.push(JSON.parse(raw.toString())))
    })
    // Fast reconnect delay so the test does not wait the production 5s.
    const fast = new RemoteTunnelClient(
      { enabled: true, relayUrl: `http://127.0.0.1:${relayPort}`, psk: 'test-psk' },
      { reconnectDelayMs: 50 },
    )
    client = fast
    try {
      fast.connect(true)
      await new Promise<void>((resolve) => wss!.once('connection', () => resolve()))
      await new Promise((resolve) => setTimeout(resolve, 50))

      const info = fast.createSession()
      await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(1))

      // Force a tunnel drop: the client socket closes; it must reconnect on
      // the fast timer and re-register the retained pairing unchanged.
      ;(fast as unknown as { ws: WebSocket }).ws.close()
      await new Promise((resolve) => setTimeout(resolve, 300))

      const registers = received.filter((m) => m.type === 'session.register')
      expect(registers.length).toBeGreaterThanOrEqual(2)
      expect(registers[registers.length - 1]!.payload.sessionId).toBe(info.sessionId)
      expect(registers[registers.length - 1]!.payload.pairingToken).toBe(info.pairingToken)
    } finally {
      if (previousRoot === undefined) delete process.env.DSH_REMOTE_DATA_ROOT
      else process.env.DSH_REMOTE_DATA_ROOT = previousRoot
      fsMod.rmSync(tmpRoot, { recursive: true, force: true })
    }
  })

  it('getSession(): expired pairing hides the QR (returns null) but the session is retained for re-registration', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)
    const info = c.createSession()
    // Backdate the pairing past its 5-minute QR window.
    ;(c as unknown as { sessions: Map<string, RemoteSessionInfo> }).sessions.get(info.sessionId)!.expiresAt = Date.now() - 1000
    expect(c.getSession()).toBeNull()
    // The retained pairing still re-registers on a reconnect (fresh client
    // simulation: close + fast reconnect would re-send it — assert retention
    // via the internal map instead of sleeping the reconnect timer).
    const retained = (c as unknown as { sessions: Map<string, RemoteSessionInfo> }).sessions.get(info.sessionId)
    expect(retained?.sessionId).toBe(info.sessionId)
    expect(retained?.pairingToken).toBe(info.pairingToken)
  })

  it('v3.170 多配对共存：createSession 不清旧 sessions，新旧配对并存；重连各自补注册', async () => {
    const received: ReceivedMessage[] = []
    wss = new WebSocketServer({ port: 0 })
    const port = (wss.address() as { port: number }).port
    wss.on('connection', (socket: WsServerSocket) => {
      socket.on('message', (raw) => received.push(JSON.parse(raw.toString())))
    })
    const fast = new RemoteTunnelClient(
      { enabled: true, relayUrl: `http://127.0.0.1:${port}`, psk: 'test-psk' },
      { reconnectDelayMs: 30, persist: false },
    )
    client = fast
    fast.connect(true)
    await new Promise<void>((resolve) => wss!.once('connection', () => resolve()))
    await new Promise((resolve) => setTimeout(resolve, 50))

    const a = fast.createSession()
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(1))

    const b = fast.createSession()
    expect(a.sessionId).not.toBe(b.sessionId)
    // v3.170：不再自动 revoke 旧配对——共存储存
    expect(received.filter((m) => m.type === 'session.revoke').length).toBe(0)
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(2))
    // 本地多槽：a 与 b 同时存在
    expect(fast.getSessions().map((s) => s.sessionId).sort()).toEqual([a.sessionId, b.sessionId].sort())

    // 隧道断开重连：现存两条都补注册，a 不会被「顶替」
    ;(fast as unknown as { ws: WebSocket }).ws.close()
    await new Promise((resolve) => setTimeout(resolve, 250))
    const registers = received.filter((m) => m.type === 'session.register')
    // 重连后的两次 register 应分别对应 a 与 b（顺序无保证，用集合断言）
    const reconnectedSids = new Set(registers.slice(-2).map((m) => m.payload.sessionId))
    expect(reconnectedSids).toEqual(new Set([a.sessionId, b.sessionId]))
  })

  it('落盘恢复：createSession 写入 data root 文件，新客户端实例（模拟引擎重启）恢复并补注册', async () => {
    const os = await import('node:os')
    const fsMod = await import('node:fs')
    const tmpRoot = fsMod.mkdtempSync(os.tmpdir() + '/remote-sessions-test-')
    process.env.DSH_REMOTE_DATA_ROOT = tmpRoot
    try {
      const received: ReceivedMessage[] = []
      const spinWss = (): string => {
        wss = new WebSocketServer({ port: 0 })
        const port = (wss.address() as { port: number }).port
        wss.on('connection', (socket: WsServerSocket) => {
          socket.on('message', (raw) => received.push(JSON.parse(raw.toString())))
        })
        return `http://127.0.0.1:${port}`
      }
      const first = new RemoteTunnelClient(
        { enabled: true, relayUrl: spinWss(), psk: 'test-psk' },
        { reconnectDelayMs: 30 },
      )
      client = first
      first.connect(true)
      await new Promise((resolve) => setTimeout(resolve, 80))
      const info = first.createSession()

      // 文件已落盘且含该会话（v3.141：落盘 JSON 不再含 mode 字段）
      const file = fsMod.readdirSync(tmpRoot).find((f) => f.endsWith('remote-sessions.json'))
      expect(file).toBeDefined()
      const saved = JSON.parse(fsMod.readFileSync(`${tmpRoot}/${file}`, 'utf-8'))
      expect(saved.sessions.map((s: { sessionId: string }) => s.sessionId)).toContain(info.sessionId)
      expect(saved.sessions.map((s: { mode?: string }) => s.mode).every((m: string | undefined) => m === undefined)).toBe(true)

      // 模拟引擎重启：全新实例（内存为空）从文件恢复；新 wss 会话断言补注册
      first.disconnect()
      received.length = 0
      const second = new RemoteTunnelClient(
        { enabled: true, relayUrl: spinWss(), psk: 'test-psk' },
        { reconnectDelayMs: 30 },
      )
      client = second
      second.connect(true)
      await vi.waitFor(() => {
        const r = received.filter((m) => m.type === 'session.register')
        expect(r.length).toBeGreaterThanOrEqual(1)
        expect(r[r.length - 1]!.payload.sessionId).toBe(info.sessionId)
      })
      expect(second.getSessions().some((s) => s.sessionId === info.sessionId)).toBe(true)
    } finally {
      delete process.env.DSH_REMOTE_DATA_ROOT
      fsMod.rmSync(tmpRoot, { recursive: true, force: true })
    }
  })

  it('revokeSession(sessionId)：撤销单条配对；revokeAllSessions：清空全部', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)
    const a = c.createSession()
    const b = c.createSession()
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(2))
    // 多配对共存：两条都在
    expect(c.getSessions().map((s) => s.sessionId).sort()).toEqual([a.sessionId, b.sessionId].sort())

    // revokeSession 撤销 a——只发 1 条 revoke，b 保持
    const ok = await c.revokeSession(a.sessionId)
    expect(ok).toBe(true)
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.revoke').length).toBe(1))
    const revokeFrame = received.find((m) => m.type === 'session.revoke')!
    expect(revokeFrame.payload.sessionId).toBe(a.sessionId)
    expect(c.getSessions().map((s) => s.sessionId)).toEqual([b.sessionId])

    // revokeAllSessions 清空剩下 1 条
    const revoked = await c.revokeAllSessions()
    expect(revoked).toBe(1)
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.revoke').length).toBe(2))
    expect(c.getSessions()).toHaveLength(0)
  })

  it('revokeSession 不存在的 sessionId 返回 false 不下发 revoke 帧', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)
    c.createSession()
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(1))
    const ok = await c.revokeSession('sess_nonexistent_xxx')
    expect(ok).toBe(false)
    expect(received.filter((m) => m.type === 'session.revoke').length).toBe(0)
  })

  it('断开后撤销：隧道不在时 revokeAll 临时拉起连接送达 session.revoke，再收回 manual-off（撤销丢失守卫）', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)
    const a = c.createSession()
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(1))

    // 先手动断开隧道（复现卡片旧行为的事故顺序：隧道没了配对还在）
    c.setTunnelEnabled(false)
    expect(c.getConnectionState().state).toBe('manual-off')

    // 撤销必须仍能送达：临时拉起连接，revoke 要出现在 wss 侧
    const revoked = await c.revokeAllSessions()
    expect(revoked).toBe(1)
    await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.revoke').length).toBe(1))
    expect(received.find((m) => m.type === 'session.revoke')!.payload.sessionId).toBe(a.sessionId)

    // 送达后收回：恢复 manual-off，不得留下自动重连
    await new Promise((resolve) => setTimeout(resolve, 150))
    expect(c.getConnectionState().state).toBe('manual-off')
    expect(c.getConnectionState().manualOff).toBe(true)
    expect(c.getSessions()).toHaveLength(0)
  })

  it('隧道手动开关：断开后 manual-off 且不自动重连；重连后恢复 connected', async () => {
    const received: ReceivedMessage[] = []
    const { client: c } = await spinRelay(received)
    expect(c.getConnectionState().state).toBe('connected')

    const off = c.setTunnelEnabled(false)
    expect(off.state).toBe('manual-off')
    expect(off.manualOff).toBe(true)

    // 断开是用户意图：连接若再被外力关闭也不得自动重连
    await new Promise((resolve) => setTimeout(resolve, 200))
    expect(c.getConnectionState().state).toBe('manual-off')
    expect(c.getConnectionState().manualOff).toBe(true)

    const on = c.setTunnelEnabled(true)
    await vi.waitFor(() => expect(c.getConnectionState().state).toBe('connected'))
    expect(on.manualOff).toBe(false)
  })

  // v3.173：URL 会话 token(第三条路)
  describe('mintUrlSession (v3.173)', () => {
    it('默认 24h TTL + URL 结构同构(SPA 据此组 Bearer)', async () => {
      const received: ReceivedMessage[] = []
      const { client: c } = await spinRelay(received)
      c.createSession()
      await vi.waitFor(() => expect(received.filter((m) => m.type === 'session.register').length).toBe(1))

      const url = c.mintUrlSession()
      const u = new URL(url)
      // v3.176:根路径而非 /__pair——URL 会话不颁 cookie,gate 直接验 Bearer
      expect(u.pathname).toBe('/')
      expect(u.searchParams.get('sessionId')).toBeTruthy()
      expect(u.searchParams.get('hash')).toMatch(/^[A-Za-z0-9_-]{43}$/)
      expect(u.searchParams.get('exp')).toMatch(/^[0-9]{1,20}$/)
      expect(u.searchParams.get('mid')).toMatch(/^[a-f0-9]{64}$/)
      expect(u.searchParams.get('t')).toMatch(/^[0-9]{1,20}$/)
      const t = Number(u.searchParams.get('t'))
      const exp = Number(u.searchParams.get('exp'))
      expect(exp - t).toBe(24 * 3600 * 1000)
      const u2 = new URL(c.mintUrlSession(undefined, { ttlSeconds: 3600 }))
      expect(Number(u2.searchParams.get('exp')) - Number(u2.searchParams.get('t'))).toBe(3600 * 1000)
    })
  })

  it('跨进程收养：长跑实例收养另一进程落盘的新配对并经活隧道补注册', async () => {
    const os = await import('node:os')
    const fsMod = await import('node:fs')
    const tmpRoot = fsMod.mkdtempSync(os.tmpdir() + '/remote-adoption-test-')
    try {
      const received: ReceivedMessage[] = []
      wss = new WebSocketServer({ port: 0 })
      const port = (wss.address() as { port: number }).port
      wss.on('connection', (socket: WsServerSocket) => {
        socket.on('message', (raw) => received.push(JSON.parse(raw.toString())))
      })
      // serve 形态：长跑实例，持久化开启，dataRoot 指向 tmp
      const serve = new RemoteTunnelClient(
        { enabled: true, relayUrl: `http://127.0.0.1:${port}`, psk: 'test-psk' },
        { reconnectDelayMs: 30, dataRoot: tmpRoot },
      )
      client = serve
      serve.connect(true)
      await new Promise<void>((resolve) => wss!.once('connection', () => resolve()))
      await new Promise((resolve) => setTimeout(resolve, 60))

      // 另一个进程（pair）落盘一枚新配对（不经 serve 的内存）
      const foreign = {
        sessionId: `sess_foreign_${Date.now().toString(16)}`,
        pairingToken: 'f'.repeat(64),
        qrUrl: '',
        expiresAt: Date.now() + 3600_000,
        createdAt: Date.now(),
      }
      fsMod.writeFileSync(`${tmpRoot}/remote-sessions.json`, JSON.stringify({ version: 1, sessions: [foreign] }))

      // 收养轮询（2s）后 serve 应经自己的活隧道补注册该配对
      await vi.waitFor(() => {
        const r = received.filter((m) => m.type === 'session.register' && m.payload.sessionId === foreign.sessionId)
        expect(r.length).toBeGreaterThanOrEqual(1)
      }, { timeout: 8000 })
      // 收养进内存：后续重连也会带上
      expect(serve.getSessions().some((s) => s.sessionId === foreign.sessionId)).toBe(true)
    } finally {
      fsMod.rmSync(tmpRoot, { recursive: true, force: true })
    }
  })
})
