export interface RelayMessage<T = unknown> {
  type: string;
  id?: string;
  sessionId?: string;
  payload?: T;
  error?: string;
  timestamp: number;
}

export interface RegisterSessionPayload {
  sessionId: string;
  pairingToken: string;
  ttlSeconds: number;
  /** Engine shared secret (DSH_BIND_TOKEN) read by the plugin inside the dsh
   * process. Injected as X-App-Token on relayed HTTP/WS so the v3.41 engine
   * lockdown accepts relay traffic (relay design predates it — phones can't
   * know the token). Rotates per engine boot and is re-delivered with every
   * tunnel (re)registration; in-memory only, never persisted. Hand-copied on
   * the plugin side per M01 decision #4.
   *
   * v3.141：删除了 v3.106 的 `mode?: 'readonly'|'full'` 字段（v3.141 起单模式化
   * ——所有配对等价于 full；详见
   * docs/decisions/2026-09-07-remote-single-mode.md）。仍在协议面忽略该字段以容忍
   * 过渡部署期间的旧 plugin。*/
  engineToken?: string;
  metadata?: {
    deviceName?: string;
    hostname?: string;
  };
}

export interface RevokeSessionPayload {
  sessionId: string;
  reason?: string;
}

export interface ClientAuthPayload {
  sessionId: string;
  pairingToken: string;
  sessionCookie?: string;
}
