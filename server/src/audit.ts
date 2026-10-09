import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

/**
 * Append-only audit log — the record of truth the watchdog analyses. WAL +
 * busy_timeout because the watchdog is a separate process reading this file
 * while the relay keeps writing (same discipline as the state store).
 */
export interface AuditRecord {
  sessionId?: string;
  eventType: string;
  ip: string;
  userAgent?: string;
  details?: string;
}

export class RelayAuditLogger {
  private db: DatabaseSync | null = null;

  constructor(dbPath: string = path.join(process.cwd(), 'data', 'relay-audit.db')) {
    try {
      // DatabaseSync creates files but never parent directories — without
      // this the first deployment silently loses ALL audit logging.
      fs.mkdirSync(path.dirname(dbPath), { recursive: true });
      this.db = new DatabaseSync(dbPath);
      this.db.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;');
      this.init();
    } catch {
      this.db = null;
    }
  }

  private init() {
    if (!this.db) return;
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS audit_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT,
        event_type TEXT NOT NULL,
        ip TEXT NOT NULL,
        user_agent TEXT,
        details TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_audit_session ON audit_logs(session_id);
      CREATE INDEX IF NOT EXISTS idx_audit_event ON audit_logs(event_type);
    `);
  }

  public log(record: AuditRecord) {
    if (!this.db) return;
    try {
      const stmt = this.db.prepare(`
        INSERT INTO audit_logs (session_id, event_type, ip, user_agent, details)
        VALUES (?, ?, ?, ?, ?)
      `);
      stmt.run(
        record.sessionId || null,
        record.eventType,
        record.ip,
        record.userAgent || null,
        record.details || null
      );
    } catch {}
  }

  public close() {
    if (this.db) {
      try {
        this.db.close();
      } catch {}
      this.db = null;
    }
  }
}
