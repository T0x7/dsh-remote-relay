/**
 * v3.282 long-tail hardening: frame/body limits, XFF trust, audit hygiene.
 *
 * Each case exists because the relaxed behaviour was real: a single events
 * bridge could push unbounded frames in either direction; request bodies were
 * capped at fastify's default 1MB while the tunnel allowed 4MB (size mismatch
 * by deployment); the bare upgrade handlers trusted any client's
 * X-Forwarded-For, so audit IPs were forgeable and the per-IP brute-force
 * alarm could never fire; and audit details carried the first 36 bytes of
 * cookie headers — bearer credentials — into a SQLite store pino's redaction
 * never reaches.
 */
import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { buildServer } from '../src/index.js';
import { resolveClientIp, cookieFingerprint } from '../src/index.js';
import WebSocket from 'ws';
import { createLogger } from '../src/logger.js';
import path from 'node:path';
import fs from 'node:fs';

const TEST_PSK = 'test-secret-psk-123456';
const PUBLIC_HOST = 'relay.test.local';
const silentLogger = createLogger('silent');

function tmpDb(name: string): { dbPath: string; stateDbPath: string } {
  const dbPath = path.join(process.cwd(), 'data', `test-${name}-audit.db`);
  const stateDbPath = path.join(process.cwd(), 'data', `test-${name}-state.db`);
  for (const f of [dbPath, stateDbPath]) if (fs.existsSync(f)) fs.unlinkSync(f);
  return { dbPath, stateDbPath };
}

describe('v3.282 frame + body limits', () => {
  let fastifyInstance: any;
  let auditLogger: any;
  const { dbPath, stateDbPath } = tmpDb('limits');
  let port: number;

  beforeEach(async () => {
    const server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: 'http://127.0.0.1:1', publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  async function connectTunnel(): Promise<WebSocket> {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    await new Promise((resolve, reject) => {
      ws.once('open', resolve);
      ws.once('close', (code) => reject(new Error(`closed ${code}`)));
    });
    return ws;
  }

  it('an oversized frame on the tunnel gets the socket closed, not buffered', async () => {
    const ws = await connectTunnel();
    const closed = new Promise<{ code: number }>((resolve) => ws.once('close', (code) => resolve({ code })));
    // 5MB > the 4MB maxPayload — ws refuses the frame and closes 1009.
    ws.send(Buffer.alloc(5 * 1024 * 1024));
    const { code } = await closed;
    expect(code).toBe(1009);
  });

  it('a request body over the shared 4MB limit is rejected with 413', async () => {
    // Land a pairing so the credential gate passes and the body parser is what answers.
    const ws = await connectTunnel();
    ws.send(JSON.stringify({ type: 'session.register', payload: { sessionId: 'sess_limit', pairingToken: 'token_limit', ttlSeconds: 300 } }));
    await new Promise((resolve) => ws.once('message', resolve));
    const land = await fetch(`http://127.0.0.1:${port}/?sessionId=sess_limit&token=token_limit`, { redirect: 'manual' });
    expect(land.status).toBe(302);
    const cookie = (land.headers.get('set-cookie') || '').split(';')[0];

    const res = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      method: 'POST', headers: { cookie, 'content-type': 'application/json' },
      body: JSON.stringify({ pad: 'x'.repeat(5 * 1024 * 1024) }),
    });
    // 413 (body limit), NOT 403 — the limit fires before routing decisions.
    expect(res.status).toBe(413);
    ws.close();
  });
});

describe('v3.282 XFF trust (bare-upgrade paths)', () => {
  it('honours XFF only from a directly connected trusted proxy', () => {
    expect(resolveClientIp('127.0.0.1', '203.0.113.9', '127.0.0.1,::1')).toBe('203.0.113.9');
  });

  it('ignores XFF from any other direct peer — the claim is not auditable', () => {
    expect(resolveClientIp('198.51.100.7', '203.0.113.9', '127.0.0.1,::1')).toBe('198.51.100.7');
    expect(resolveClientIp('198.51.100.7', 'anything', '')).toBe('198.51.100.7');
  });

  it('falls back to the direct address when the proxy sends no XFF', () => {
    expect(resolveClientIp('127.0.0.1', undefined, '127.0.0.1,::1')).toBe('127.0.0.1');
    expect(resolveClientIp(undefined, undefined, '127.0.0.1')).toBe('unknown');
  });
});

describe('v3.282 cookie fingerprint keeps values out of the audit store', () => {
  it('records names and value lengths, never value bytes', () => {
    const fp = cookieFingerprint('dsh_remote_session__sess_abc=SECRETVALUE; other=x');
    expect(fp).toContain('dsh_remote_session__sess_abc:len=11');
    expect(fp).toContain('other:len=1');
    expect(fp).not.toContain('SECRETVALUE');
  });

  it('NONE without a header, and never throws on malformed cookies', () => {
    expect(cookieFingerprint(undefined)).toBe('NONE');
    expect(cookieFingerprint('')).toBe('NONE');
    expect(cookieFingerprint('garbage-without-equals')).toMatch(/^1条 /);
  });
});
