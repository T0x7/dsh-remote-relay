import { useState, useEffect } from 'react';
import type { SettingsFormModel } from '@deepseek-ai/dsh-client-ui-primitives';
import { zh } from './locales.ts';
import { RelayConfigForm } from './RelayConfigForm.tsx';
import type { RelayConfigValues, SecretSlot } from './relay-config-model.ts';
import qrcode from 'qrcode-generator';

interface RemoteSessionInfo {
  sessionId: string;
  qrUrl: string;
  expiresAt: number;
  // v3.141: RemoteSessionInfo.mode 已删除（单模式化）
  createdAt: number;
}

interface StatusPayload {
  tunnel?: { state: TunnelState; relayUrl: string; manualOff?: boolean };
  active?: RemoteSessionInfo | null;
  sessions?: RemoteSessionInfo[];
  devices?: Array<{ sessionId: string; online: boolean; onlineWs: number; lastSeen: number | null; ip?: string | null }> | null;
}

/** Tunnel-level connection state surfaced on the settings card. */
export type TunnelState = 'connected' | 'connecting' | 'reconnecting' | 'disabled' | 'manual-off';

const TUNNEL_BADGE: Record<TunnelState, { text: string; bg: string; fg: string }> = {
  connected: { text: '🟢 已连接中继', bg: 'rgba(80,200,120,0.15)', fg: '#69f0ae' },
  connecting: { text: '🟡 连接中继中…', bg: 'rgba(255,213,79,0.15)', fg: '#ffd54f' },
  reconnecting: { text: '🟡 中继重连中…', bg: 'rgba(255,213,79,0.15)', fg: '#ffd54f' },
  disabled: { text: '⚪ 远程通道未启用', bg: 'rgba(160,160,160,0.15)', fg: '#aaa' },
  'manual-off': { text: '🔴 已手动断开中继', bg: 'rgba(183,28,28,0.12)', fg: '#e57373' },
};

/** 本地渲染二维码（不再依赖外部 qrserver 服务）：data 内容全部自生成。 */
function qrSvg(text: string): string {
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  return qr.createSvgTag({ cellSize: 4, margin: 2, scalable: false });
}

function fmtDate(ts: number): string {
  const d = new Date(ts);
  return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

export function RemoteSettingsCard(props: {
  view?: 'summary' | 'page'
  relayForm?: SettingsFormModel<RelayConfigValues>
  /** Secret-slot existence the Host reports; values never ride a response. Omit to hide the form. */
  secrets?: readonly SecretSlot[] | undefined
}) {
  // 0.1.7 插件页：列表渲染 one-liner，详情页渲染全卡。
  if (props?.view === 'summary') return zh.title;
  const [status, setStatus] = useState<StatusPayload | null>(null);
  // Single-mode pairing: no mode selector. POST /dsh-remote/session
  // 不再读 mode 字段（远程控制等价于完整控制）。
  const [loading, setLoading] = useState(false);
  const [toggling, setToggling] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [, setTick] = useState(0);
  // v3.176：URL 会话链接(浏览器多设备)——点按钮生成根路径 /? 链接,展示 + 复制
  // v3.176.3：URL 会话独立入口 UI 已按需求移除（只留 QR 一个入口；QR 本身
  // 就是根路径 URL 会话链接，复制二维码下方的链接即可在浏览器打开）。

  const fetchStatus = async () => {
    try {
      const res = await fetch('/dsh-remote/session');
      if (!res.ok) {
        setError(`状态获取失败（${res.status}）——请在 Mac 本机操作（远程通道不支持此操作）`);
        return;
      }
      const data = await res.json();
      setError(null);
      setStatus(data);
    } catch {
      setError('状态获取失败——隧道/引擎可能不在线');
    }
  };

  useEffect(() => {
    fetchStatus();
    const interval = setInterval(fetchStatus, 3000);
    const sec = setInterval(() => setTick((n) => n + 1), 1000);
    return () => { clearInterval(interval); clearInterval(sec); };
  }, []);

  const handleEnable = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch('/dsh-remote/session', { method: 'POST' });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        setError(data.hint || data.error || `开启失败（${res.status}）`);
        return;
      }
      const data = await res.json();
      setError(null);
      await fetchStatus();
      setStatus((prev) => ({
        ...(prev?.tunnel ? { tunnel: prev.tunnel } : {}),
        active: data,
        sessions: [...(prev?.sessions ?? []).filter((s) => s.sessionId !== data.sessionId), data],
      }));
    } finally {
      setLoading(false);
    }
  };

  const handleDisable = async () => {
    setLoading(true);
    try {
      await fetch('/dsh-remote/session', { method: 'DELETE' });
      setStatus((prev) => ({
        ...(prev?.tunnel ? { tunnel: prev.tunnel } : {}),
        active: null,
        sessions: [],
      }));
    } finally {
      setLoading(false);
    }
  };

  const handleDisconnectAll = async () => {
    // 断开 = 终止远程控制：隧道关闭 + 撤销全部配对。恢复唯一路径是重新
    // 选择模式并扫码（用户拍板语义：断开必须彻底，不做一键重连）。
    if (!window.confirm('断开中继并撤销所有已配对设备？已配对设备将立即失效，恢复需在本机重新选择模式并扫码。')) {
      return;
    }
    setToggling(true);
    try {
      // 顺序关键：先撤销（趁隧道活着送达 relay，设备 cookie 立即失效），
      // 再断隧道——反过来撤销会在隧道关闭后丢在本地，宽限期内设备仍可访问
      await fetch('/dsh-remote/session', { method: 'DELETE' });
      await fetch('/dsh-remote/tunnel', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'disconnect' }),
      });
      await fetchStatus();
    } finally {
      setToggling(false);
    }
  };

  const devices = status?.devices ?? null;
  const active = status?.active ?? null;
  // QR 倒计时（tick 触发重算；过期即回落到保留列表视图）
  const qrExpired = active !== null && Date.now() >= active.expiresAt;
  const qrRemainSec = active && !qrExpired ? Math.max(0, Math.ceil((active.expiresAt - Date.now()) / 1000)) : 0;
  const sessions = status?.sessions ?? [];
  const tunnel = status?.tunnel;
  const badge = tunnel ? TUNNEL_BADGE[tunnel.state] : TUNNEL_BADGE.connecting;

  return (
    <div style={{ padding: 16, border: '1px solid var(--border-subtle, #333)', borderRadius: 8 }}>
      <h3 style={{ margin: '0 0 12px 0' }}>公网远程控制 (Remote Relay)</h3>
      <p style={{ color: '#888', fontSize: 13 }}>
        通过安全的出站中继通道，使用手机扫码即可直接查看和操作当前 dsh 实例。
      </p>

      {error ? (
        <div style={{ marginTop: 12, padding: '8px 10px', borderRadius: 6, fontSize: 12, background: 'rgba(183,28,28,0.15)', color: '#e57373' }}>
          {error}
        </div>
      ) : null}

      {/* 中继连接配置（relay 地址 / PSK / 引擎地址 / 启用开关）—— 配对与状态区
          之上。仅当挂载层传入了表单模型才渲染：插件详情页是唯一的配置入口，
          设置区/远程只读面不传，天然不出现表单。 */}
      {props?.relayForm ? (
        <RelayConfigForm model={props.relayForm} secrets={props.secrets} />
      ) : null}

      {/* 隧道连接状态：远程在线与否一眼可见 + 断开入口（断开即撤销全部配对） */}
      <div style={{ marginTop: 10, display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ display: 'inline-block', padding: '2px 10px', borderRadius: 10, fontSize: 12, background: badge.bg, color: badge.fg }}>
          {badge.text}
          {tunnel && tunnel.state === 'connected' ? <span style={{ color: '#888' }}> · {tunnel.relayUrl.replace(/^https?:\/\//, '')}</span> : null}
        </span>
        {sessions.length > 0 || tunnel?.state === 'connected' ? (
          <button
            onClick={handleDisconnectAll}
            disabled={toggling}
            style={{
              fontSize: 12, padding: '2px 10px', borderRadius: 10, cursor: 'pointer',
              border: '1px solid #b71c1c', background: 'transparent', color: '#e57373',
            }}
          >
            {toggling ? '…' : '断开中继'}
          </button>
        ) : null}
      </div>
      {tunnel?.manualOff || tunnel?.state === 'disabled' ? (
        <div style={{ marginTop: 6, fontSize: 12, color: '#e57373' }}>
          中继已断开，所有已配对设备已失效。恢复远程访问：点击下方「开启远程控制」生成新二维码 → 手机重新扫码。
        </div>
      ) : null}
      {tunnel?.state === 'connected' && sessions.length === 0 ? (
        <div style={{ marginTop: 6, fontSize: 12, color: '#8ab4f8' }}>
          连接正常，尚无配对设备——点击下方「开启远程控制」生成 24 小时有效的配对二维码（在本机生成，远程只读页面无法生成）。
        </div>
      ) : null}

      {active && !qrExpired ? (
        <div style={{ marginTop: 16, textAlign: 'center' }}>
          <div
            style={{ background: '#fff', padding: 10, display: 'inline-block', borderRadius: 4 }}
            dangerouslySetInnerHTML={{ __html: qrSvg(active.qrUrl) }}
          />
          <div
            style={{
              marginTop: 8, display: 'inline-block', padding: '2px 10px', borderRadius: 10, fontSize: 12,
              background: 'rgba(80,200,120,0.15)', color: '#69f0ae',
            }}
          >
            ⚡ 完整控制会话
            ：二维码 {Math.floor(qrRemainSec / 60)}分{String(qrRemainSec % 60).padStart(2, '0')}秒后失效（失效不影响已配对设备）
          </div>
          <div style={{ marginTop: 8, fontSize: 12, color: '#aaa', wordBreak: 'break-all' }}>
            扫码访问：<code>{active.qrUrl}</code>
          </div>
        </div>
      ) : null}

      {/* 已配对会话保留列表 + 设备在线状态：在线判据来自 relay
          （活跃事件流或 60s 内请求）。v3.204 单浏览器独占（按引擎）：同一台
          Mac 同时仅 1 台设备在线，新设备打开任意配对链接会顶替旧设备（90 秒
          宽限）；引擎短暂断线（<10 分钟）自动恢复，超宽限后需重新扫码 */}
      {sessions.length > 0 ? (
        <div style={{ marginTop: 14 }}>
          <div style={{ fontSize: 12, color: '#aaa' }}>
            {devices
              ? `在线设备 ${devices.filter((d) => d.online).length} · 已配对 ${sessions.length}（同一台 Mac 同时仅 1 台在线：新设备连接会顶替旧设备）`
              : `已配对 ${sessions.length} 个远程会话（同时仅 1 台设备在线，新设备连接会顶替旧设备；Mac 引擎离线超约 10 分钟后需重新扫码）`}
          </div>
          <div style={{ marginTop: 6, fontSize: 12, color: '#bbb' }}>
            {sessions.map((s) => {
              const dev = devices?.find((d) => d.sessionId === s.sessionId);
              const online = dev?.online === true;
              return (
                <div key={s.sessionId} style={{ display: 'flex', justifyContent: 'space-between', padding: '2px 0' }}>
                  <span>
                    {online ? '🟢' : '⚪'} ⚡ {s.sessionId}
                  </span>
                  <span style={{ color: '#777' }}>
                    {dev?.lastSeen
                      ? `最近活跃 ${fmtDate(dev.lastSeen)}${dev?.ip != null && dev.ip !== '' ? ` · IP ${dev.ip}` : ''}`
                      : `${fmtDate(s.createdAt)} 配对`}
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      ) : null}

      <div style={{ marginTop: 12 }}>
        {/* v3.141：单模式化——删除 mode 选择器。开启按钮直接生成配对。 */}
        <button
          onClick={handleEnable}
          disabled={loading}
          style={{ background: '#1976d2', color: '#fff', border: 'none', padding: '8px 20px', borderRadius: 4, cursor: 'pointer' }}
        >
          {loading ? '开启中...' : '开启远程控制'}
        </button>
        {sessions.length > 0 ? (
          <button
            onClick={handleDisable}
            disabled={loading}
            style={{ background: '#d32f2f', color: '#fff', border: 'none', padding: '8px 20px', borderRadius: 4, cursor: 'pointer', marginLeft: 8 }}
          >
            断开所有远程连接
          </button>
        ) : null}
      </div>

      {/* v3.176.3：URL 会话独立入口已移除——QR（根路径签名 URL，24h）就是
          唯一远程入口；扫码或把 QR 链接粘到浏览器打开均走同一 URL 会话。 */}
    </div>
  );
}
