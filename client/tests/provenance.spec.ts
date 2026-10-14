/**
 * v3.282 request provenance.
 *
 * The engine's listener cannot tell a bridged request from a local browser's
 * — both arrive on loopback from this process. The ONLY thing that
 * distinguishes them is a header this tunnel stamps on the way through, so
 * two properties are load-bearing and both are pinned here:
 *
 *  1. every header set the client builds for the engine carries it, and
 *  2. a paired device can neither forge nor suppress it — its own copy is
 *     stripped before the tunnel sets its own.
 *
 * Without (1) the plugin's admin routes answer phones. Without (2) the
 * boundary is a suggestion any device can opt out of.
 */
import { describe, expect, it } from 'vitest'
import { RemoteTunnelClient, markForwardedAsRemote, REMOTE_TUNNEL_MARKER_HEADER } from '../src/tunnel.ts'

/** Headers a device must never be able to pass through to the engine. */
const FORBIDDEN = [
  REMOTE_TUNNEL_MARKER_HEADER,
  'forwarded',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
]

describe('v3.282 request provenance (tunnel → engine)', () => {
  it('stamps the marker on a bare header set', () => {
    const marked = markForwardedAsRemote({})
    expect(marked[REMOTE_TUNNEL_MARKER_HEADER]).toBe('1')
  })

  it('strips a device-supplied marker and x-forwarded-* before stamping its own', () => {
    const marked = markForwardedAsRemote({
      [REMOTE_TUNNEL_MARKER_HEADER]: '0',
      forwarded: 'for=203.0.113.9',
      'x-forwarded-for': '203.0.113.9',
      'x-forwarded-host': 'attacker.example',
      'x-forwarded-proto': 'https',
      cookie: 'dsh_remote_session=abc',
    })
    for (const name of FORBIDDEN) {
      if (name === REMOTE_TUNNEL_MARKER_HEADER) {
        expect(marked[name]).toBe('1') // theirs is gone, ours stands
      } else {
        expect(marked[name]).toBeUndefined()
      }
    }
    // Everything else survives untouched.
    expect(marked.cookie).toBe('dsh_remote_session=abc')
  })

  it('cannot be suppressed: a device that blanks the header still gets stamped', () => {
    const marked = markForwardedAsRemote({ [REMOTE_TUNNEL_MARKER_HEADER]: '' })
    expect(marked[REMOTE_TUNNEL_MARKER_HEADER]).toBe('1')
  })

  it('the production header builder actually applies it (HTTP data plane)', () => {
    const client = new RemoteTunnelClient(
      { enabled: true, relayUrl: 'http://127.0.0.1:1', psk: 'test-psk' },
      { persist: false },
    )
    const build = (client as unknown as {
      buildUpstreamHeadersInline: (h: Record<string, string>, host: string, token?: string) => Record<string, string>
    }).buildUpstreamHeadersInline.bind(client)

    const headers = build({ 'x-forwarded-for': '203.0.113.9' }, 'relay.example.com', 'engine-token')
    expect(headers[REMOTE_TUNNEL_MARKER_HEADER]).toBe('1')
    expect(headers['x-forwarded-for']).toBeUndefined()
    // The rest of the production contract is unchanged by the stamp.
    expect(headers.host).toBe('relay.example.com')
    expect(headers['x-app-token']).toBe('engine-token')
    expect(headers['accept-encoding']).toBe('identity')
    client.disconnect()
  })

  it('the WS bridge shares the same header builder, so upgrades carry it too', () => {
    // handleWsUpgrade builds its upstream headers through
    // buildUpstreamHeadersInline — pin that fact structurally rather than
    // trusting the two call sites to stay in sync by hand.
    const src = new RemoteTunnelClient(
      { enabled: true, relayUrl: 'http://127.0.0.1:1', psk: 'test-psk' },
      { persist: false },
    )
    const proto = Object.getPrototypeOf(src) as { handleWsUpgrade: unknown }
    const body = proto.handleWsUpgrade.toString()
    expect(body).toContain('buildUpstreamHeadersInline')
    src.disconnect()
  })
})