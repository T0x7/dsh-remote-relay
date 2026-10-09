import type { Context as ClientContext } from '@deepseek-ai/cordis'
/**
 * Client half of the dsh remote-control plugin. Registers the
 * RemoteSettingsCard on exactly ONE surface: the bundle's own configuration
 * page in the dsh Plugins panel (`plugins.bundle.config`, keyed by the npm
 * package name), which carries the full card — relay-connection form
 * (中继地址 / 共享密钥 / 引擎地址 / 启用开关), pairing QR + link, devices.
 *
 * There is deliberately no Settings nav section: the relay address and PSK
 * are configured in one place only, on the page gated to local operators
 * (the Plugins panel is hidden remotely; see REMOTE_GATING_CSS). Card state
 * drives the Host routes under /dsh-remote.
 */

import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-ui-settings/client'
import type {} from '@deepseek-ai/dsh-client-ui-plugin-manager/client' // plugins.bundle.config slot type
import { RemoteSettingsCard } from './RemoteSettingsCard.tsx'
// createRelayForm constructs a SettingsFormModel over the shared Host form, so
// it lives in the JSX view module (it new()s a class from ui-primitives).
// Importing it here keeps index.ts's dsh surface to services only; the vitest
// alias replaces this specifier with a stub in bare checkouts.
import { createRelayForm } from './RelayConfigForm.tsx'
import { ENTRY_ID } from './relay-config-model.ts'
import { en } from './locales.en.ts'
import { zh, type RemoteCardLocaleKey } from './locales.ts'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'  // v3.139：ctx.slots 类型增广（0.1.2 起声明移此）

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** dsh-remote card copy. */
    'settings.dshRemote': RemoteCardLocaleKey
  }
}

/** Dictionary namespace owned by this plugin's client half. */
const NS = 'settings.dshRemote'

/**
 * The bundle's npm package name — the key `plugins.bundle.config` is keyed
 * by, and the id the client module system registers this half under. Must
 * stay byte-identical to package.json `name`.
 */
export const BUNDLE_PACKAGE = 'dsh-remote-relay-plugin'

/**
 * Services: slots for the registrations, locale for copy, configForms for the
 * relay-connection form (its form writes go to the Host, which validates and
 * persists them into the profile patch).
 */
export const inject = ['slots', 'locale', 'configForms']

/**
 * PRIVILEGED-entry gating for non-loopback origins (remote relay channel).
 * dsh's /api fence hard-blocks 16 PRIVILEGED methods loopback-only
 * (client/connection/src/index.ts PRIVILEGED_METHODS, mirrored in
 * ../remote-capability.ts); surfacing their UI entries over the relay
 * yields raw HTTP 403 dialogs. Hide the entries instead. Kept as a CSS
 * patch in this plugin's client bundle so dsh core stays untouched;
 * tests/gating.client.spec.ts pins the selectors.
 *
 * nav nth-child contract with the schedule/realtime plugin sections present
 * (6 items): 1=general(0) 2=models(10) 3=plugins(15) 4=agent-presets(20)
 * 5=schedule(28) 6=schedule(35). We hide 2-4
 * (REMOTE_HIDDEN_NAV_SECTIONS); the schedule panels stay visible by decision
 * — plain plugin HTTP routes, no PRIVILEGED /api surface, and remote timer
 * control is core remote value. This bundle contributes NO settings.nav row
 * (configuration lives only on the Plugins detail page), so the contract ends
 * at 6 — adding a section back shifts these indices.
 */
const REMOTE_GATING_CSS = `
/* host.pickDirectory entries: hero workspace chip + sidebar "+" */
button[aria-label="选择工作区"], button[aria-label="Choose workspace"] { display: none !important; }
button[aria-label="添加工作区"], button[aria-label="Add workspace"] { display: none !important; }
/* settings nav: hide Models / Plugins / Agent-presets (PRIVILEGED-heavy) */
[class$="_navList"] > button:nth-child(2),
[class$="_navList"] > button:nth-child(3),
[class$="_navList"] > button:nth-child(4) { display: none !important; }
`

/** Inject the gating stylesheet on non-loopback origins. Exported for tests/gating.client.spec.ts. */
export function injectRemoteGatingCss(): void {
  if (typeof document === 'undefined') return
  const hostname = globalThis.location?.hostname ?? ''
  const isLoopback =
    hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1'
  if (isLoopback) return
  if (document.getElementById('dsh-remote-gating') !== null) return
  const style = document.createElement('style')
  style.id = 'dsh-remote-gating'
  style.textContent = REMOTE_GATING_CSS
  document.head.appendChild(style)
}

// v3.141：单模式化——删除 `injectReadonlyIndicator()` 与 `detectRemoteReadonly()`：
// 远程控制恒为完整控制，relay 不再有 `/__session` 端点，客户端不再查询。

/**
 * Path prefixes whose same-origin requests carry the URL-session bearer.
 *
 * `/api/*` is dsh core and `/dsh-remote/*` is this plugin's own pairing
 * lifecycle prefix (ROUTE_PREFIX on the host half) — together they cover a
 * standalone dsh-remote-relay deployment. An engine that ALSO hosts other
 * plugins exposing their own HTTP routes over the remote channel needs those
 * prefixes listed here too (URL-session entry only; the pairing cookie
 * authorizes every same-origin path regardless of this list), and should add
 * them in this bundle's copy before building.
 */
const AUTH_PREFIXES = ['/api/', '/dsh-remote/'] as const

/** True when a same-origin path is one this injector must authorize. */
function needsAuth(pathname: string): boolean {
  return AUTH_PREFIXES.some((prefix) => pathname.startsWith(prefix))
}

// URL session token injection — when the browser opens a URL carrying
// sessionId/token/hash/t/exp/mid, assemble the signature into
// `Authorization: Bearer <sid>.<exp>.<mid>.<t>.<hash>` and inject it into
// matching same-origin requests (including the WebSocket query ?token=), so
// each tab authenticates with its own pairing instead of a shared cookie jar.
//
// Activates only when the URL carries all five fields (otherwise silent
// no-op; the desktop app and the plain cookie path are unaffected).
export function installUrlSessionAuth(): () => void {
  if (typeof globalThis.location === 'undefined') return () => {}
  const params = new URLSearchParams(globalThis.location.search)
  const sid = params.get('sessionId')
  const exp = params.get('exp')
  const mid = params.get('mid')
  const t = params.get('t')
  const hash = params.get('hash')
  if (!sid || !exp || !mid || !t || !hash) return () => {}
  const bearer = [sid, exp, mid, t, hash].join('.')

  // (1) fetch injection: match on the PARSED pathname — dsh's client RPC
  // builds absolute URLs from location.origin, so a plain startsWith('/api/')
  // check misses every absolute URL and the bearer is never injected.
  const origFetch = globalThis.fetch.bind(globalThis)
  globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const u = typeof input === 'string' ? input : input instanceof URL ? input.href : (input as Request).url
    try {
      const target = new URL(u, globalThis.location.href)
      if (target.origin === globalThis.location.origin && needsAuth(target.pathname)) {
        init = { ...init }
        init.headers = new Headers(init.headers)
        ;(init.headers as Headers).set('authorization', `Bearer ${bearer}`)
      }
    } catch {
      // URL parse failure (non-http forms) — pass through untouched
    }
    return origFetch(input, init)
  }

  // (2) WebSocket injection: the browser event streams (/api/events.*,
  // /api/remote.mux) cannot carry custom headers — append the token to the
  // query instead.
  const OrigWebSocket = globalThis.WebSocket
  const PatchedWebSocket = function (this: WebSocket, url: string | URL, protocols?: string | string[]) {
    const target = new URL(url)
    if (needsAuth(target.pathname)) {
      if (!target.searchParams.has('token')) {
        target.searchParams.set('token', bearer)
      }
    }
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    return new OrigWebSocket(target.toString(), protocols as string)
  } as unknown as typeof WebSocket
  PatchedWebSocket.prototype = OrigWebSocket.prototype
  ;(PatchedWebSocket as unknown as { CONNECTING: number; OPEN: number; CLOSING: number; CLOSED: number }).CONNECTING = OrigWebSocket.CONNECTING
  ;(PatchedWebSocket as unknown as { CONNECTING: number; OPEN: number; CLOSING: number; CLOSED: number }).OPEN = OrigWebSocket.OPEN
  ;(PatchedWebSocket as unknown as { CONNECTING: number; OPEN: number; CLOSING: number; CLOSED: number }).CLOSING = OrigWebSocket.CLOSING
  ;(PatchedWebSocket as unknown as { CONNECTING: number; OPEN: number; CLOSING: number; CLOSED: number }).CLOSED = OrigWebSocket.CLOSED
  globalThis.WebSocket = PatchedWebSocket

  return () => {
    globalThis.fetch = origFetch
    globalThis.WebSocket = OrigWebSocket
  }
}

/** 401 burst watchdog — when credentials (a 24h URL session, or the pairing
 * cookie) die while the page is open, the already-loaded dsh SPA shell never
 * exits on its own and sits at "Reconnecting…" forever. The relay can only
 * answer 401 JSON on /api (the fetch contract) and cannot drive a browser
 * navigation, so the guard lives in the injection layer: 3 consecutive 401s
 * on same-origin data-plane paths (with no successful response in between)
 * mean the credential is dead, and we location.replace() to the relay's
 * dedicated expired page /__expired instead of staying inside the dsh shell.
 *
 * Anti-false-positive: cross-origin and non-data-plane 401s are not counted,
 * and any non-401 response resets the counter — in the ~5s window where the
 * tunnel re-registers after a relay restart there are at most 1-2 401s, far
 * below the threshold. Loopback (desktop app / local dsh) never installs it:
 * a data-plane 401 cannot happen locally and must never redirect. */
export function installAuthFailureWatchdog(expiredPath = '/__expired'): () => void {
  if (typeof globalThis.location === 'undefined') return () => {}
  const hostname = globalThis.location.hostname ?? ''
  const isLoopback =
    hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1'
  if (isLoopback) return () => {}

  const AUTH_FAILURE_THRESHOLD = 3
  let consecutive = 0
  let redirected = false
  // Deliberately not .bind() — keep the original reference so teardown
  // restores it exactly (vi.fn does not depend on `this`).
  const origFetch = globalThis.fetch
  globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    return origFetch(input, init).then((res) => {
      if (!redirected) {
        let sameOriginDataPlane = false
        try {
          const u = typeof input === 'string' ? input : input instanceof URL ? input.href : (input as Request).url
          const target = new URL(u, globalThis.location.href)
          sameOriginDataPlane = target.origin === globalThis.location.origin && needsAuth(target.pathname)
        } catch { /* non-http form — skip counting */ }
        if (sameOriginDataPlane) {
          if (res.status === 401) {
            consecutive += 1
            if (consecutive >= AUTH_FAILURE_THRESHOLD) {
              redirected = true
              globalThis.location.replace(expiredPath)
            }
          } else {
            consecutive = 0
          }
        }
      }
      return res
    })
  }
  return () => { globalThis.fetch = origFetch }
}

/** v3.205：设备顶替看门狗——relay 在着陆轮换密钥时以 close(4001,
 * 'device_replaced') 掐断旧设备的事件流（实时踢人）。本看门狗包装
 * window.WebSocket 观察所有实例的 close 事件：code 4001 → 跳转
 * /__expired?reason=replaced（专属「已在另一台设备连接」页）。
 *
 * 设计要点：
 *  - close 码即权威信号，不做二次凭证校验——90s previousSecret 宽限内旧
 *    cookie 的检查仍会通过，二次校验会被宽限窗"骗"（误判自己还活着）；
 *  - 只认 4001；其它 close 码（1000/1006/1012…）交给 dsh 自身重连逻辑；
 *  - loopback（桌面 App / 本机 dsh）不安装——本机没有 relay 顶替语义。 */
export function installDeviceReplacedWatchdog(replacedPath = '/__expired?reason=replaced'): () => void {
  if (typeof globalThis.location === 'undefined') return () => {}
  const hostname = globalThis.location.hostname ?? ''
  const isLoopback =
    hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1'
  if (isLoopback) return () => {}

  const win = globalThis as unknown as { WebSocket?: typeof WebSocket }
  const Original = win.WebSocket
  if (typeof Original !== 'function') return () => {}
  let redirected = false
  // 构造函数显式返回对象时 new 表达式取该对象——实例能力全部来自真 WS；
  // 静态常量与 prototype 对齐 instanceof 语义。
  const Patched = function (this: unknown, url: string | URL, protocols?: string | string[]) {
    const ws = protocols === undefined ? new Original(url) : new Original(url, protocols)
    ws.addEventListener('close', (ev: CloseEvent) => {
      if (!redirected && ev.code === 4001) {
        redirected = true
        globalThis.location.replace(replacedPath)
      }
    })
    return ws
  } as unknown as typeof WebSocket
  Patched.prototype = Original.prototype
  // lib.dom 的静态常量是 readonly——经中间对象绕过赋值检查
  const statics = Patched as unknown as Record<'CONNECTING' | 'OPEN' | 'CLOSING' | 'CLOSED', number>
  statics.CONNECTING = Original.CONNECTING
  statics.OPEN = Original.OPEN
  statics.CLOSING = Original.CLOSING
  statics.CLOSED = Original.CLOSED
  win.WebSocket = Patched
  return () => { win.WebSocket = Original }
}

/**
 * Register the dictionary and the Plugins-tab configuration card (the one
 * surface this bundle renders on).
 * @param ctx - client root context.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'dsh-remote: dictionaries')

  // URL session token injection (browser multi-device, no cookie jar).
  installUrlSessionAuth()

  // 401 burst watchdog — when credentials die while the page is open, jump
  // to the relay's dedicated expired page /__expired instead of sitting in
  // dsh's "Reconnecting…". Must be installed AFTER installUrlSessionAuth so
  // it observes that layer's final responses.
  installAuthFailureWatchdog()

  // Device-replacement watchdog — a relay close(4001) kicks the session in
  // real time; the SPA jumps to the "connected on another device" page as
  // soon as it sees the code.
  installDeviceReplacedWatchdog()

  // Non-loopback origin (relay channel): hide PRIVILEGED-gated UI entries.
  injectRemoteGatingCss()

  // The relay-connection form. `ctx.configForms.get(ENTRY_ID)` is the settings
  // domain's shared form for this Host entry (settings derives the namespace
  // from the Loader row's id); the model wraps it and is disposed with the
  // fiber, since it holds a subscription. The card receives it as a prop so
  // this module stays plain .ts and the components keep typed props only.
  const relayForm = createRelayForm(ctx.configForms.get(ENTRY_ID))
  ctx.effect(() => () => { relayForm.dispose() }, 'dsh-remote: config form')
  // A secret's value never rides a response; the mirror reports only whether a
  // slot holds one, which is all the write-only control needs.
  const describe = ctx.configForms.describe()
  const secretSlots = () =>
    describe.getSnapshot().view?.namespaces.find((namespace) => namespace.ns === ENTRY_ID)?.secrets

  // The bundle's configuration page — the ONLY surface this plugin renders
  // on. Per the dsh plugin spec (ui-plugin-manager), a THIRD-PARTY bundle
  // renders its configuration on its bundle detail page via
  // `plugins.bundle.config` keyed by the npm package name; `plugins.item` is
  // the slot for OFFICIAL plugins and is the wrong home here. Full card:
  // relay-connection form (中继地址 / 共享密钥 / 引擎地址 / 启用开关) at the top,
  // pairing QR + link, devices.
  // The registration lives exactly while this bundle's Loader row is on (the
  // client module system attaches this half to the bare-package-name row), so
  // no whileServed gating is needed.
  //
  // There is deliberately NO settings.section entry: one configuration home,
  // on the page that is gated to local operators. The earlier Settings-nav
  // section existed so a paired phone could still reach a status / QR /
  // disconnect surface; it was dropped so the relay address and PSK are never
  // reachable from a second surface, and the phone loses the card (the Mac
  // admin page remains the single place to read state, mint the QR, and
  // revoke pairings).
  const ConfigCard = (props: { view?: 'summary' | 'page' }) =>
    RemoteSettingsCard({ ...props, relayForm, secrets: secretSlots() })
  ctx.slots.inject('plugins.bundle.config', () => ctx.slots.register({
    name: 'plugins.bundle.config',
    key: BUNDLE_PACKAGE,
    locale: NS,
    inject: () => ({}),
  }, ConfigCard))
}
