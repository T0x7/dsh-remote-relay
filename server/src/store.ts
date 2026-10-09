import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

/**
 * Persisted pairing state (data/relay-state.db) so a relay restart or a dsh
 * tunnel blip does not invalidate every phone's 30-day cookie. WAL +
 * busy_timeout because the watchdog process reads the sibling audit DB —
 * same discipline as the audit logger, both DBs live on the relay-data
 * volume. The sessionSecrets are credentials at rest; the volume must be
 * treated like any other secret store (see ADR 2026-08-30-relay-public-hardening).
 */
export interface StoredSession {
  sessionId: string;
  pairingToken: string;
  sessionSecret: string;
  /** ms epoch of first pairing — anchors the absolute cookie cap. */
  createdAt: number;
  /** ms epoch of the pairing-token window (QR landing validity). */
  expiresAt: number;
  /** ms epoch when the dsh tunnel dropped; null while bound. */
  disconnectedAt: number | null;
  /** ms epoch of the first real device connection (token consumption point,
   * v3.128.1); null until a device connects. */
  connectedAt: number | null;
}

export class SessionStore {
  private db: DatabaseSync | null = null;

  constructor(dbPath: string = path.join(process.cwd(), 'data', 'relay-state.db')) {
    try {
      fs.mkdirSync(path.dirname(dbPath), { recursive: true });
      this.db = new DatabaseSync(dbPath);
      this.db.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;');
      this.db.exec(`
        CREATE TABLE IF NOT EXISTS sessions (
          session_id TEXT PRIMARY KEY,
          pairing_token TEXT NOT NULL,
          session_secret TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          disconnected_at INTEGER,
          connected_at INTEGER
        );
      `);
      // v3.128.1：已存在的库补列（duplicate column 报错吞掉即可）
      try { this.db.exec('ALTER TABLE sessions ADD COLUMN connected_at INTEGER'); } catch {}
      // v3.141：v3.106 加的 mode 列保留（不写不读，平滑遗留库），但不再出现在
      // 接口面。生产库兼容不需要迁移。
    } catch {
      // Unpersistable store degrades to in-memory sessions (pre-v3.119
      // behavior): pairings die on relay restart instead of refusing to boot.
      this.db = null;
    }
  }

  get available(): boolean {
    return this.db !== null;
  }

public upsert(record: StoredSession): void {
    if (!this.db) return;
    try {
      this.db
        .prepare(
          `INSERT INTO sessions (session_id, pairing_token, session_secret, created_at, expires_at, disconnected_at, connected_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(session_id) DO UPDATE SET
             pairing_token = excluded.pairing_token,
             session_secret = excluded.session_secret,
             created_at = excluded.created_at,
             expires_at = excluded.expires_at,
             disconnected_at = excluded.disconnected_at,
             connected_at = excluded.connected_at`
        )
        .run(
          record.sessionId,
          record.pairingToken,
          record.sessionSecret,
          record.createdAt,
          record.expiresAt,
          record.disconnectedAt,
          record.connectedAt,
        );
    } catch {}
  }

  public remove(sessionId: string): void {
    if (!this.db) return;
    try {
      this.db.prepare('DELETE FROM sessions WHERE session_id = ?').run(sessionId);
    } catch {}
  }

  public load(): StoredSession[] {
    if (!this.db) return [];
    try {
      // v3.141：v3.106 加的 mode 列保留在 SELECT 列表里（避免 v3.106/v3.141
      // 之间部署的库列顺序假设），但不再写回 StoredSession。生产库不需要迁移。
      const rows = this.db
        .prepare('SELECT session_id, pairing_token, session_secret, created_at, expires_at, disconnected_at, connected_at FROM sessions')
        .all() as Array<Record<string, unknown>>;
      return rows.map((row) => ({
        sessionId: String(row.session_id),
        pairingToken: String(row.pairing_token),
        sessionSecret: String(row.session_secret),
        createdAt: Number(row.created_at),
        expiresAt: Number(row.expires_at),
        disconnectedAt: row.disconnected_at == null ? null : Number(row.disconnected_at),
        connectedAt: row.connected_at == null ? null : Number(row.connected_at),
      }));
    } catch {
      return [];
    }
  }

  public close(): void {
    if (this.db) {
      try {
        this.db.close();
      } catch {}
      this.db = null;
    }
  }
}
