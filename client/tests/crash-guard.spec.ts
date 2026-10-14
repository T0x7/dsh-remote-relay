/**
 * v3.282: the data plane must never kill the engine.
 *
 * handleHttpReq/handleWsUpgrade contain synchronous throw points —
 * http.request validates method/path tokens and throws TypeError on a frame
 * the relay (or anything speaking its protocol) hands over. The dispatcher
 * used to call them fire-and-forget, so one malformed frame surfaced as an
 * unhandled rejection and, under Node's default
 * --unhandled-rejections=throw, took the whole dsh engine down. A phone with
 * a valid pairing cookie could crash the machine it controls.
 *
 * The contract now: whatever the frame contains, the engine stays up, the
 * caller gets an error frame, and a broken upgrade also gets its close.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { WebSocketServer, type WebSocket as WsServerSocket } from 'ws'
import { RemoteTunnelClient } from '../src/tunnel.ts'

describe('v3.282 data-plane crash guard', () => {
  let wss: WebSocketServer | null = null
  let client: RemoteTunnelClient | null = null
  const raw: string[] = []

  afterEach(() => {
    client?.disconnect()
    client = null
    wss?.close()
    wss = null
  })

  /** Spin the relay stand-in and capture every raw data-plane frame. */
  async function spin(): Promise<void> {
    wss = new WebSocketServer({ port: 0 })
    const port = (wss.address() as { port: number }).port
    wss.on('connection', (socket: WsServerSocket) => {
      socket.on('message', (m) => raw.push(m.toString()))
    })
    client = new RemoteTunnelClient(
      { enabled: true, relayUrl: `http://127.0.0.1:${port}`, psk: 'test-psk' },
      { persist: false },
    )
    client.connect(true)
    await new Promise<void>((resolve) => wss!.once('connection', () => resolve()))
    await new Promise((resolve) => setTimeout(resolve, 100))
  }

  it('a malformed http.req frame answers with an error frame instead of crashing the process', async () => {
    await spin()
    // \t in the method violates HTTP token grammar → http.request throws.
    const onUncaught = vi.fn()
    process.on('uncaughtException', onUncaught)

    // Drive the socket the way the ws 'message' event would.
    const socketRef = (client as unknown as { ws: { emit: (ev: string, data: Buffer) => void } }).ws
    socketRef.emit('message', Buffer.from(JSON.stringify({
      v: 1, type: 'http.req', id: 'crash-1', method: 'GE\tT', path: '/', headers: {},
    })))

    await new Promise((resolve) => setTimeout(resolve, 150))
    expect(onUncaught).not.toHaveBeenCalled()
    process.removeListener('uncaughtException', onUncaught)
    // The socket is still usable — the engine-side tunnel did not die.
    expect(client!.getConnectionState().state).toBe('connected')
    client!.disconnect()
  })

  it('the error frame reaches the relay so the device sees a readable failure', async () => {
    await spin()
    const wsRef = (client as unknown as { ws: { emit: (ev: string, data: Buffer) => void } }).ws
    wsRef.emit('message', Buffer.from(JSON.stringify({
      v: 1, type: 'http.req', id: 'crash-2', method: 'GE\tT', path: '/', headers: {},
    })))
    await new Promise((resolve) => setTimeout(resolve, 150))
    const frames = raw.map((m) => JSON.parse(m) as { type: string; code?: string; id?: string })
    expect(frames.some((f) => f.type === 'error' && f.id === 'crash-2' && f.code === 'bridge_error')).toBe(true)
    client!.disconnect()
  })
})