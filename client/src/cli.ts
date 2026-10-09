#!/usr/bin/env node
/**
 * dsh-remote-client — headless CLI for the dsh-remote-relay client side.
 *
 *   dsh-remote-client serve            connect the tunnel and keep it alive
 *   dsh-remote-client pair             mint a new pairing (prints URL + terminal QR)
 *   dsh-remote-client list             list retained pairings
 *   dsh-remote-client share            mint an extra signed URL session link
 *   dsh-remote-client devices          relay-side device presence snapshot
 *   dsh-remote-client revoke <id|all>  revoke one pairing (or all)
 *
 * Config: flags > env (DSH_REMOTE_RELAY_URL, DSH_REMOTE_PSK / RELAY_PSK,
 * DSH_BIND_HOST, DSH_BIND_PORT, DSH_BIND_TOKEN, DSH_REMOTE_DATA_ROOT).
 */

import { RemoteTunnelClient } from './tunnel.ts';
import type { RemoteRelayConfig } from './tunnel.ts';

interface Args {
  command: string;
  positional: string[];
  flags: Record<string, string | boolean>;
}

function parseArgs(argv: string[]): Args {
  const flags: Record<string, string | boolean> = {};
  const positional: string[] = [];
  let command = 'serve';
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        flags[key] = next;
        i++;
      } else {
        flags[key] = true;
      }
    } else if (positional.length === 0 && !a.startsWith('-')) {
      command = a;
    } else {
      positional.push(a);
    }
  }
  return { command, positional, flags };
}

function usage(): never {
  console.log(`dsh-remote-client — pair a local dsh engine with a dsh-remote-relay server

Usage:
  dsh-remote-client <command> [options]

Commands:
  serve                       connect the tunnel and keep it alive (default)
  pair                        mint a new pairing; prints the signed URL + terminal QR
  list                        list retained pairings
  share [--ttl <sec>] [--name <name>]
                              mint an extra signed URL session link (max 24h)
  devices                     show relay-side device presence snapshot
  revoke <sessionId|all>      revoke one pairing (or all)

Options:
  --relay-url <url>           relay origin, e.g. https://relay.example.com
  --psk <psk>                 tunnel PSK (must equal the server RELAY_PSK)
  --data-root <dir>           persistence dir (default ~/.dsh-remote-relay)

Environment:
  DSH_REMOTE_RELAY_URL        relay origin (fallback for --relay-url)
  DSH_REMOTE_PSK | RELAY_PSK  tunnel PSK
  DSH_BIND_HOST / DSH_BIND_PORT   local engine bind (default 127.0.0.1:3080)
  DSH_BIND_TOKEN              engine X-App-Token (dsh lockdown); optional
  DSH_REMOTE_DATA_ROOT        persistence dir override
`);
  process.exit(0);
}

function baseConfig(args: Args): RemoteRelayConfig {
  const relayUrl = (args.flags['relay-url'] as string) ?? process.env.DSH_REMOTE_RELAY_URL ?? '';
  const psk = (args.flags.psk as string) ?? process.env.DSH_REMOTE_PSK ?? process.env.RELAY_PSK ?? '';
  if (!relayUrl || !psk) {
    console.error('error: relay url and psk are required (--relay-url / --psk, or DSH_REMOTE_RELAY_URL + DSH_REMOTE_PSK)');
    process.exit(1);
  }
  return {
    relayUrl,
    psk,
    enabled: true,
    upstreamHost: process.env.DSH_BIND_HOST,
    upstreamPort: process.env.DSH_BIND_PORT ? Number(process.env.DSH_BIND_PORT) : undefined,
    engineToken: process.env.DSH_BIND_TOKEN,
  };
}

function makeClient(args: Args): RemoteTunnelClient {
  const dataRoot = (args.flags['data-root'] as string) ?? process.env.DSH_REMOTE_DATA_ROOT;
  return new RemoteTunnelClient(baseConfig(args), {
    reconnectDelayMs: 5000,
    ...(dataRoot ? { dataRoot } : {}),
  });
}

/** One-shot commands must not linger on the client's heartbeat/IP-probe
 * timers — close the tunnel and exit explicitly. */
function finish(client: RemoteTunnelClient, code = 0): never {
  client.disconnect();
  process.exit(code);
}

async function waitForTunnel(client: RemoteTunnelClient, timeoutMs = 8000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (client.getConnectionState().state === 'connected') return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return client.getConnectionState().state === 'connected';
}

/** Terminal ASCII QR (██ / ␣␣ two-char cells so the aspect ratio survives
 * monospace rendering); quiet zone of 2 modules. */
async function renderQr(text: string): Promise<string> {
  // Lazy import keeps non-pair commands free of the dependency at startup.
  const mod = await import('qrcode-generator');
  const qrcode = (mod.default ?? mod) as (
    typeNumber: number,
    errorCorrectionLevel: 'L' | 'M' | 'Q' | 'H',
  ) => { addData(s: string): void; make(): void; getModuleCount(): number; isDark(r: number, c: number): boolean };
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  const quiet = 2;
  const lines: string[] = [];
  for (let r = 0; r < n + quiet * 2; r++) {
    let line = '';
    for (let c = 0; c < n + quiet * 2; c++) {
      const dark = r >= quiet && c >= quiet && r < n + quiet && c < n + quiet && qr.isDark(r - quiet, c - quiet);
      line += dark ? '██' : '  ';
    }
    lines.push(line);
  }
  return lines.join('\n');
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (args.flags.help || args.command === 'help') usage();

  const client = makeClient(args);

  switch (args.command) {
    case 'serve': {
      console.log(`[dsh-remote-client] relay: ${baseConfig(args).relayUrl}`);
      client.connect(true);
      const report = () => {
        const { state, relayUrl } = client.getConnectionState();
        console.log(`[dsh-remote-client] state=${state} pairings=${client.getSessions().length} relay=${relayUrl}`);
      };
      report();
      setInterval(report, 30_000).unref();
      const keepAlive = setInterval(() => {}, 1 << 30);
      const shutdown = () => {
        clearInterval(keepAlive);
        client.disconnect();
        process.exit(0);
      };
      process.on('SIGINT', shutdown);
      process.on('SIGTERM', shutdown);
      break;
    }

    case 'pair': {
      client.connect(true);
      const connected = await waitForTunnel(client);
      if (!connected) {
        console.error(`error: tunnel did not connect (state=${client.getConnectionState().state}) — check relay url / psk / server reachability`);
        finish(client, 1);
      }
      const info = client.createSession();
      console.log(`\npairing sessionId : ${info.sessionId}`);
      console.log(`expires          : ${new Date(info.expiresAt).toISOString()}`);
      console.log(`\nScan this URL with your phone (or open it there directly):\n`);
      console.log(info.qrUrl);
      try {
        console.log(`\n${await renderQr(info.qrUrl)}\n`);
      } catch {
        // terminal QR is best-effort; the URL above is the source of truth
      }
      finish(client);
    }

    case 'list': {
      const sessions = client.getSessions();
      if (sessions.length === 0) {
        console.log('no retained pairings');
      } else {
        const now = Date.now();
        for (const s of sessions) {
          const expired = s.expiresAt <= now ? ' (QR window closed — retained for rebind)' : '';
          console.log(`${s.sessionId}  created=${new Date(s.createdAt).toISOString()}  qr-expires=${new Date(s.expiresAt).toISOString()}${expired}`);
        }
      }
      finish(client);
    }

    case 'share': {
      const ttl = args.flags.ttl ? Number(args.flags.ttl) : undefined;
      const name = typeof args.flags.name === 'string' ? args.flags.name : undefined;
      const url = client.mintUrlSession(undefined, { ...(ttl !== undefined ? { ttlSeconds: ttl } : {}), ...(name ? { name } : {}) });
      console.log(url);
      finish(client);
    }

    case 'devices': {
      const devices = await client.getDevices();
      if (!devices) {
        console.error('error: relay unreachable (and no cached snapshot)');
        finish(client, 1);
      }
      if (devices.length === 0) {
        console.log('no registered pairings on the relay');
      } else {
        for (const d of devices) {
          console.log(`${d.sessionId}  online=${d.online} paired=${d.paired} ws=${d.onlineWs} lastSeen=${d.lastSeen ? new Date(d.lastSeen).toISOString() : 'never'}`);
        }
      }
      finish(client);
    }

    case 'revoke': {
      const target = args.positional[0];
      if (!target) {
        console.error('error: revoke needs a sessionId or "all"');
        process.exit(1);
      }
      if (target === 'all') {
        const n = await client.revokeAllSessions();
        console.log(`revoked ${n} pairing(s)`);
        finish(client);
      } else {
        const ok = await client.revokeSession(target);
        console.log(ok ? `revoked ${target}` : `${target}: not found locally`);
        finish(client, ok ? 0 : 1);
      }
      break;
    }

    default:
      console.error(`error: unknown command "${args.command}" (try: serve | pair | list | share | devices | revoke)`);
      process.exit(1);
  }
}

void main();
