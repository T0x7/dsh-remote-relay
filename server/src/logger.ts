import pino from 'pino';

/**
 * Structured operational log for the relay: JSON lines on stdout, which is
 * what docker/compose logging drivers collect and rotate. Security-relevant
 * events (auth failures, gate rejections, tunnel lifecycle) log HERE for
 * operators while the append-only audit DB (audit.ts) remains the record of
 * truth for the watchdog. Redaction is a seatbelt: call sites must still log
 * identifiers (sessionId), never token/secret values.
 */
export function createLogger(level?: string): pino.Logger {
  return pino({
    level: level ?? process.env.LOG_LEVEL ?? 'info',
    redact: {
      paths: [
        'psk',
        'pairingToken',
        'sessionSecret',
        'cookie',
        'authorization',
        'req.headers.cookie',
        'req.headers.authorization',
      ],
      censor: '[REDACTED]',
    },
    base: { svc: 'dsh-remote-relay' },
  });
}

export type RelayLogger = pino.Logger;
