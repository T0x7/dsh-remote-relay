/**
 * v3.282: one truth per fact.
 *
 * Before this, the tunnel's on-screen state could be wrong in four different
 * ways at once, and each had a test-shaped hole:
 *
 *   - the disconnect intent lived only in process memory, so a restart lost it
 *     while `enabled` survived — the card could show both "not enabled" and
 *     "disconnected by hand";
 *   - changing the relay address or the PSK adopted the new value without
 *     re-dialling, so the badge named a relay the socket was not connected to;
 *   - two concurrent config commits opened two sockets and orphaned one;
 *   - revoking pairings from a disabled engine dialed the tunnel back up.
 *
 * Each case below is a behaviour, not a comment.
 */
import { afterEach, describe, expect, it } from 'vitest'
import { mkdtempSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WebSocketServer, type WebSocket as WsServerSocket } from 'ws'
import { RemoteTunnelClient } from '../src/tunnel.ts'

const roots: string[] = []

function dataRoot(): string {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-remote-state-'))
  roots.push(dir)
  return dir
}

afterEach(() => {
  for (const dir of roots.splice(0)) rmSync(dir, { recursive: true, force: true })
})

/** A relay stand-in that counts how many tunnels actually dial in. */
function spinRelay(): { url: string; connections: () => number; close: () => void } {
  const wss = new WebSocketServer({ port: 0 })
  const port = (wss.address() as { port: number }).port
  let connections = 0
  wss.on('connection', (socket: WsServerSocket) => { connections += 1 })
  return {
    url: `http://127.0.0.1:${port}`,
    connections: () => connections,
    close: () => wss.close(),
  }
}

function clientOf(root: string, url: string, overrides: Record<string, unknown> = {}): RemoteTunnelClient {
  return new RemoteTunnelClient(
    { enabled: true, relayUrl: url, psk: 'test-psk', ...overrides },
    { dataRoot: root, reconnectDelayMs: 10_000 },
  )
}

const settle = (ms = 150) => new Promise((resolve) => setTimeout(resolve, ms))

describe('v3.282 state truth', () => {
  it('a manual disconnect survives a restart (the fact outlives the process)', async () => {
    const relay = spinRelay()
    try {
      const root = dataRoot()
      const first = clientOf(root, relay.url)
      first.connect(true)
      await settle()
      expect(first.getConnectionState().state).toBe('connected')

      first.setTunnelEnabled(false)
      expect(first.getConnectionState().state).toBe('manual-off')
      first.disconnect()

      // A fresh client over the same data root = an engine restart.
      const second = clientOf(root, relay.url)
      expect(second.getConnectionState().state).toBe('manual-off')
      second.connect() // the boot path: enabled, so it tries to dial
      await settle()
      expect(second.getConnectionState().state).not.toBe('connected')
      second.disconnect()
    } finally {
      relay.close()
    }
  })

  it('re-enabling clears the disconnect intent for good', async () => {
    const relay = spinRelay()
    try {
      const root = dataRoot()
      const client = clientOf(root, relay.url)
      client.setTunnelEnabled(false)
      client.setTunnelEnabled(true)
      await settle()
      expect(client.getConnectionState().state).toBe('connected')
      client.disconnect()

      expect(clientOf(root, relay.url).getConnectionState().state).not.toBe('manual-off')
    } finally {
      relay.close()
    }
  })

  it('changing relay_url re-dials onto the new relay', async () => {
    const before = spinRelay()
    const after = spinRelay()
    try {
      const client = clientOf(dataRoot(), before.url)
      client.connect(true)
      await settle()
      expect(before.connections()).toBe(1)
      expect(after.connections()).toBe(0)

      client.updateConfig({ relayUrl: after.url })
      await settle()
      expect(after.connections()).toBe(1)
      expect(client.getConnectionState().relayUrl).toBe(after.url)
      client.disconnect()
    } finally {
      before.close()
      after.close()
    }
  })

  it('changing the PSK re-dials (the old socket authenticated as the old identity)', async () => {
    const relay = spinRelay()
    try {
      const client = clientOf(dataRoot(), relay.url)
      client.connect(true)
      await settle()
      expect(relay.connections()).toBe(1)

      client.updateConfig({ psk: 'rotated-psk' })
      await settle()
      expect(relay.connections()).toBe(2)
      client.disconnect()
    } finally {
      relay.close()
    }
  })

  it('concurrent config commits do not stack tunnels', async () => {
    const relay = spinRelay()
    try {
      const client = clientOf(dataRoot(), relay.url)
      client.updateConfig({ upstream_port: 3080 })
      client.updateConfig({ upstream_host: '127.0.0.1' })
      await settle()
      expect(relay.connections()).toBe(1)
      client.disconnect()
    } finally {
      relay.close()
    }
  })

  it('force does NOT bypass enabled: revoking from a disabled engine stays dark', async () => {
    const relay = spinRelay()
    try {
      const client = clientOf(dataRoot(), relay.url, { enabled: false })
      client.connect(true)
      await settle(250)
      expect(relay.connections()).toBe(0)
      expect(client.getConnectionState().state).toBe('disabled')
      client.disconnect()
    } finally {
      relay.close()
    }
  })

  it('a disabled engine reports disabled even if a socket is somehow open', async () => {
    const relay = spinRelay()
    try {
      const client = clientOf(dataRoot(), relay.url)
      client.connect(true)
      await settle()
      expect(client.getConnectionState().state).toBe('connected')

      client.updateConfig({ enabled: false })
      expect(client.getConnectionState().state).toBe('disabled')
      client.disconnect()
    } finally {
      relay.close()
    }
  })

  it('persist:false keeps the filesystem untouched (it used to overwrite the real file)', async () => {
    const root = dataRoot()
    const file = join(root, 'remote-sessions.json')
    const relay = spinRelay()
    try {
      const client = new RemoteTunnelClient(
        { enabled: true, relayUrl: relay.url, psk: 'test-psk' },
        { dataRoot: root, persist: false },
      )
      client.createSession()
      client.setTunnelEnabled(false)
      await settle()
      expect(existsSync(file)).toBe(false)
      client.disconnect()
    } finally {
      relay.close()
    }
  })

  it('an undelivered revoke reports failure instead of pretending (v3.282)', async () => {
    // relayUrl points at a closed port: the frame cannot be delivered.
    const root = dataRoot()
    const client = new RemoteTunnelClient(
      { enabled: true, relayUrl: 'http://127.0.0.1:1', psk: 'test-psk' },
      { dataRoot: root, deliveryWaitMs: 150 },
    )
    const session = client.createSession()
    client.connect(true)
    await settle(100)

    expect(await client.revokeSession(session.sessionId)).toBe(false)
    // The local copy MUST survive: the device is still usable during the relay
    // grace window, and deleting the only record of it would make that true
    // forever with no way to re-send the revocation.
    expect(client.getSessions().map((s) => s.sessionId)).toContain(session.sessionId)

    expect(await client.revokeAllSessions()).toBe(0)
    expect(client.getSessions()).toHaveLength(1)
    client.disconnect()
  })

  it('a delivered revoke still works, and the tunnel goes back to how it was', async () => {
    const relay = spinRelay()
    try {
      const client = new RemoteTunnelClient(
        { enabled: true, relayUrl: relay.url, psk: 'test-psk' },
        { dataRoot: dataRoot(), deliveryWaitMs: 500 },
      )
      const session = client.createSession()
      client.setTunnelEnabled(false) // switched off; delivery must still happen

      expect(await client.revokeSession(session.sessionId)).toBe(true)
      expect(client.getSessions()).toHaveLength(0)
      // …and the switch the user set is still where they left it.
      expect(client.getConnectionState().state).toBe('manual-off')
      client.disconnect()
    } finally {
      relay.close()
    }
  })
})