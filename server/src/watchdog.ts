import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import { RelayAuditLogger } from './audit.js';
import { createLogger, type RelayLogger } from './logger.js';

/**
 * Relay watchdog — the "定时检查是否有入侵和 bug" leg of the deployment.
 * A separate process (docker-compose `watchdog` service, same image) reads
 * the relay's append-only audit DB on a fixed interval and raises alerts
 * when the traffic shapes look like an attack or a malfunction:
 *
 *   intrusion heuristics — pairing-landing brute force (per-IP and total
 *   auth-failure bursts inside the window), PSK tunnel probing, read-only
 *   fence probing, rate-limit saturation;
 *   bug/health heuristics — upstream WS proxy error bursts, /health probe
 *   failure, dsh tunnel down for longer than the session grace, audit DB
 *   growing past the size cap.
 *
 * Every alert is (a) logged as a structured line, (b) written back into the
 * audit DB as event_type='watchdog_alert' so the trail stays in one place,
 * and (c) POSTed to RELAY_ALERT_WEBHOOK_URL when configured (e.g. a
 * Bark/ntfy/webhook receiver). Thresholds are env-tunable; defaults are
 * conservative enough that a single phone pairing never trips them.
 */

export interface WatchdogThresholds {
  /** Analysis window for event counts (s). */
  windowSec: number;
  /** Auth failures from one IP inside the window before alerting. */
  authFailPerIp: number;
  /** Auth failures from all IPs inside the window before alerting. */
  authFailTotal: number;
  /** PSK auth failures (tunnel probing) before alerting. */
  pskFail: number;
  /** ws_proxy_error events (upstream bug/unreachability) before alerting. */
  proxyErrors: number;
  /** Audit DB file size cap (MB). */
  dbMaxMb: number;
  /** dsh tunnel down duration (s) before alerting — default outlives the
   * 10-min session grace, so by alert time phone cookies are already dead. */
  tunnelDownSec: number;
}

export function loadThresholds(env: NodeJS.ProcessEnv = process.env): WatchdogThresholds {
  return {
    windowSec: Number(env.WATCHDOG_WINDOW_SEC) || 900,
    authFailPerIp: Number(env.WATCHDOG_AUTH_FAIL_PER_IP) || 20,
    authFailTotal: Number(env.WATCHDOG_AUTH_FAIL_TOTAL) || 200,
    pskFail: Number(env.WATCHDOG_PSK_FAIL) || 5,
    proxyErrors: Number(env.WATCHDOG_PROXY_ERRORS) || 10,
    dbMaxMb: Number(env.WATCHDOG_DB_MAX_MB) || 512,
    tunnelDownSec: Number(env.WATCHDOG_TUNNEL_DOWN_SEC) || 1200,
  };
}

export interface WatchdogAlert {
  kind: string;
  severity: 'warn' | 'crit';
  message: string;
  details?: Record<string, unknown>;
}

/** Audit event types that represent authentication failures. */
const AUTH_FAIL_TYPES = [
  'pair_landing_failed',
  'gate_auth_missing',
  'api_auth_missing',
  'ws_upgrade_auth_missing',
] as const;

export interface AuditAnalysisInput {
  db: Pick<DatabaseSync, 'prepare'>;
  thresholds: WatchdogThresholds;
  auditDbPath?: string;
  now?: Date;
}

/** Pure analysis over the audit DB — returns alerts, writes nothing. */
export function analyzeAudit(input: AuditAnalysisInput): WatchdogAlert[] {
  const { db, thresholds } = input;
  const alerts: WatchdogAlert[] = [];
  const windowClause = `created_at >= datetime('now', '-' || ? || ' seconds')`;

  const typeCounts = new Map<string, number>();
  const rows = db
    .prepare(
      `SELECT event_type, COUNT(*) AS n FROM audit_logs WHERE ${windowClause} GROUP BY event_type`
    )
    .all(String(thresholds.windowSec)) as Array<{ event_type: string; n: number }>;
  for (const row of rows) typeCounts.set(row.event_type, Number(row.n));

  // — intrusion: auth-failure bursts —
  const authFailTotal = AUTH_FAIL_TYPES.reduce((sum, t) => sum + (typeCounts.get(t) ?? 0), 0);
  if (authFailTotal > thresholds.authFailTotal) {
    alerts.push({
      kind: 'auth_fail_total_burst',
      severity: 'crit',
      message: `auth failures in the last ${thresholds.windowSec}s: ${authFailTotal} (threshold ${thresholds.authFailTotal}) — likely scanning or brute-forcing the relay`,
      details: { total: authFailTotal },
    });
  }

  const perIp = db
    .prepare(
      `SELECT ip, COUNT(*) AS n FROM audit_logs
       WHERE ${windowClause} AND event_type IN (${AUTH_FAIL_TYPES.map(() => '?').join(',')})
       GROUP BY ip ORDER BY n DESC LIMIT 10`
    )
    .all(String(thresholds.windowSec), ...AUTH_FAIL_TYPES) as Array<{ ip: string; n: number }>;
  const offending = perIp.filter((row) => Number(row.n) > thresholds.authFailPerIp);
  if (offending.length > 0) {
    alerts.push({
      kind: 'auth_fail_ip_burst',
      severity: 'crit',
      message: `auth-failure burst from ${offending.length} IP(s), top ${offending[0]!.ip}: ${offending[0]!.n} hits — consider blocking at nginx`,
      details: { ips: offending },
    });
  }

  const pskFails = typeCounts.get('dsh_auth_failed') ?? 0;
  if (pskFails > thresholds.pskFail) {
    alerts.push({
      kind: 'psk_probe',
      severity: 'crit',
      message: `${pskFails} PSK auth failures in the window — someone is probing the /ws/dsh tunnel gate`,
      details: { count: pskFails },
    });
  }

  // — bug/health: upstream WS proxy errors —
  const proxyErrors = typeCounts.get('ws_proxy_error') ?? 0;
  if (proxyErrors > thresholds.proxyErrors) {
    alerts.push({
      kind: 'proxy_error_burst',
      severity: 'warn',
      message: `${proxyErrors} /api/events.* proxy errors in the window — upstream dsh unreachable or a relay bug`,
      details: { count: proxyErrors },
    });
  }

  // — health: dsh tunnel staleness (absolute, not windowed) —
  const lastTunnel = db
    .prepare(
      `SELECT event_type, created_at FROM audit_logs
       WHERE event_type IN ('dsh_connected', 'dsh_disconnected')
       ORDER BY id DESC LIMIT 1`
    )
    .get() as { event_type: string; created_at: string } | undefined;
  if (lastTunnel && lastTunnel.event_type === 'dsh_disconnected') {
    const downSecRow = db
      .prepare(
        `SELECT CAST((julianday('now') - julianday(?)) * 86400 AS INTEGER) AS sec`
      )
      .get(lastTunnel.created_at) as { sec: number } | undefined;
    const downSec = Number(downSecRow?.sec ?? 0);
    if (downSec > thresholds.tunnelDownSec) {
      alerts.push({
        kind: 'tunnel_down',
        severity: 'warn',
        message: `dsh tunnel has been down for ${downSec}s (threshold ${thresholds.tunnelDownSec}s) — phone pairings past the grace window are dead; check the dsh host`,
        details: { downSec },
      });
    }
  }

  // — health: audit DB size (runaway fill via spam) —
  if (input.auditDbPath && fs.existsSync(input.auditDbPath)) {
    const sizeMb = fs.statSync(input.auditDbPath).size / (1024 * 1024);
    if (sizeMb > thresholds.dbMaxMb) {
      alerts.push({
        kind: 'audit_db_large',
        severity: 'warn',
        message: `audit DB is ${sizeMb.toFixed(1)} MB (cap ${thresholds.dbMaxMb} MB) — archive/prune it`,
        details: { sizeMb: Math.round(sizeMb * 10) / 10 },
      });
    }
  }

  return alerts;
}

async function probeHealth(healthUrl: string): Promise<boolean> {
  try {
    const res = await fetch(healthUrl, { signal: AbortSignal.timeout(5000) });
    return res.ok;
  } catch {
    return false;
  }
}

export interface WatchdogRunOptions {
  auditDbPath: string;
  healthUrl?: string;
  thresholds?: Partial<WatchdogThresholds>;
  logger?: RelayLogger;
  webhookUrl?: string;
}

/** One full pass: analyze + health probe + emit (log, audit row, webhook). */
export async function runWatchdogOnce(options: WatchdogRunOptions): Promise<WatchdogAlert[]> {
  const logger = options.logger ?? createLogger();
  const thresholds = { ...loadThresholds(), ...options.thresholds };
  const alerts: WatchdogAlert[] = [];

  let db: DatabaseSync | null = null;
  try {
    db = new DatabaseSync(options.auditDbPath);
    db.exec('PRAGMA busy_timeout=5000;');
    // Fresh deployment: watchdog may start before the relay has written (and
    // thus created) the audit table — an empty DB is "nothing to analyse",
    // not an error.
    const hasTable = (db
      .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name='audit_logs'`)
      .get() as { name: string } | undefined) !== undefined;
    if (hasTable) {
      alerts.push(...analyzeAudit({ db, thresholds, auditDbPath: options.auditDbPath }));
    }
  } catch (err: any) {
    alerts.push({
      kind: 'watchdog_db_error',
      severity: 'crit',
      message: `cannot read audit DB at ${options.auditDbPath}: ${err.message}`,
    });
  } finally {
    try { db?.close(); } catch {}
  }

  if (options.healthUrl) {
    const healthy = await probeHealth(options.healthUrl);
    if (!healthy) {
      alerts.push({
        kind: 'relay_unhealthy',
        severity: 'crit',
        message: `health probe failed: ${options.healthUrl}`,
      });
    }
  }

  if (alerts.length === 0) return alerts;

  const audit = new RelayAuditLogger(options.auditDbPath);
  for (const alert of alerts) {
    // Index access keeps pino's `this` binding — a detached logger.error
    // loses it and throws inside pino's internals (caught by a real
    // WATCHDOG_ONCE run; vitest's 'silent' logger short-circuits earlier).
    const emit = alert.severity === 'crit' ? logger.error : logger.warn;
    emit.call(logger, { kind: alert.kind, ...alert.details }, 'watchdog_alert');
    audit.log({
      eventType: 'watchdog_alert',
      ip: 'watchdog',
      details: JSON.stringify({ kind: alert.kind, severity: alert.severity, message: alert.message, ...alert.details }),
    });
  }
  audit.close();

  const webhookUrl = options.webhookUrl ?? process.env.RELAY_ALERT_WEBHOOK_URL ?? '';
  if (webhookUrl) {
    try {
      await fetch(webhookUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ source: 'dsh-remote-relay-watchdog', ts: Date.now(), alerts }),
        signal: AbortSignal.timeout(5000),
      });
    } catch (err: any) {
      logger.warn({ err: err.message, webhookUrl }, 'watchdog_webhook_failed');
    }
  }

  return alerts;
}

async function main(): Promise<void> {
  const logger = createLogger();
  const intervalSec = Number(process.env.WATCHDOG_INTERVAL_SEC) || 300;
  const auditDbPath =
    process.env.AUDIT_DB_PATH || new URL('../data/relay-audit.db', import.meta.url).pathname;
  const healthUrl = process.env.WATCHDOG_HEALTH_URL || `http://127.0.0.1:${Number(process.env.PORT) || 8080}/health`;

  const pass = async (): Promise<void> => {
    const alerts = await runWatchdogOnce({ auditDbPath, healthUrl, logger });
    logger.info({ alerts: alerts.length }, 'watchdog_pass');
  };

  await pass();
  if (process.env.WATCHDOG_ONCE === '1') return;
  // v3.134.2：不得 unref——unref 后事件循环只剩这个定时器，进程在首轮
  // pass 后正常退出（exit 0），被 compose restart 策略拉起成 60s 启停
  // 循环（服务器实测 RestartCount 2900+，300s 轮询从未生效）。测试路径
  // 由底部 VITEST 守卫和 WATCHDOG_ONCE 短路，不靠 unref 退出。
  const timer = setInterval(() => void pass(), intervalSec * 1000);
  logger.info({ intervalSec, auditDbPath, healthUrl }, 'watchdog_started');
}

if (process.env.NODE_ENV !== 'test' && !process.env.VITEST) {
  void main();
}
