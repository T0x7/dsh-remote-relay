# Changelog

All notable changes to `dsh_remote_app` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.0.2] — 2026-10-15

修 release 包的扫码配对（屏 B）。**这两个 bug 都只在 release 出现，debug 包一切正常。**

### Fixed

- **D-115 — release 包的扫码配对（屏 B）相机不可用。** debug 包一直正常，只有
  release 会报「相机不可用 / 错误：genericError」，且相机一次都没被打开过
  （camera service 无 CONNECT 记录）。根因有两层，都是 AGP 9.x 默认的 R8
  full mode 造成的：其一，mobile_scanner 用 `::defaultBarcodeScannerFactory`
  这种伴生对象函数的可调用引用，其静态 `INSTANCE` 字段被 R8 连同伴生对象一起
  剥空，lambda 照读即 NPE；其二（修掉第一层后才暴露），ML Kit 靠反射实例化的
  `*Registrar` 无参构造器被剥，组件注册表查不到实现。插件自带的规则挡不住，因为
  它写的是 `com.google.mlkit.*`——ProGuard 的 `*` 不跨包分隔符，盖不到子包。
  修复：新增 `android/app/proguard-rules.pro` 保住 mobile_scanner 与 ML Kit 的类。
  **注意：这一类问题在 debug 包上永远复现不出来，必须在 release 包上验证。**
- **D-115 — 扫码失败时看不到真实原因。** mobile_scanner 把 `start()` 抛的任何
  `PlatformException` 都硬编码映射成 `genericError`，真因只在 `errorDetails` 里；
  界面此前只显示错误码枚举名，直接把 message 丢了。现在错误码与插件原文一并显示。
- **D-115 — 更正 `MainActivity` 里一条被实测证伪的注释。** 它写着「`adb
  screencap` 走 ADB 通道，不受 FLAG_SECURE 影响」——实测 `adb exec-out screencap
  -p` 在 App 前台时返回 **0 字节空文件**。真机读界面请用 `uiautomator dump`。

## [0.0.1] — 2026-10-14

首个公开发布的版本。**beta：功能尚未完整，接口与行为都可能变**，不承诺
semver 的兼容性保证（旧版本号 0.1.0 从未发布过，一并折进这一版）。

### Added

- **Pairing** — QR scan or signed-link paste; verify-before-store; TOFU
  certificate pinning with per-machine pin persistence; automatic credential
  renewal inside the T-2h window (`SessionScheduler`).
- **Conversations (屏 E)** — journal-backed bubble list, assistant streaming
  frames (revision-checked), tool-call nodes, composer with read-only mode
  for one-shot subagents.
- **Approvals & questions (屏 P)** — `approval/request` and
  `user-questions/request` waterfalls rendered as interactive cards; answers
  posted back over `$events/result` with the bare business payload.
- **Sessions (屏 M)** — the machine's session list over `session/list`,
  searchable metadata, archive/pin metadata surface.
- **Models & reasoning effort (屏 K)** — engine's own catalog via
  `session/modelCatalog`, per-session selection with
  "follow deployment default" semantics (no flag on the wire).
- **Context ring (屏 L)** — live context pressure, token usage, cache hit
  rate, honest-absent rendering when the engine has not reported usage.
- **Subagent teams (屏 N)** — read-only child catalog and child conversations
  (one-shot children are terminal by protocol, not by flag).
- **Jobs & host (屏 F)** — five-state job lifecycle collapsed to three cards;
  host panel with session count and plugin inventory (host metrics do not
  exist in `0.1.7-rc.2` and are declared as such instead of fabricated).
- **Lock screen** — biometric gate over the credential store.
- **Landscape** — portrait and landscape both supported and pinned by layout
  tests (`2400×1080` viewport, keyboard-inset cases).
- **Resilience** — mux carrier loss no longer strands logical streams
  (intent-set replay on reconnect); `$events` re-opened periodically to
  defeat a deaf long-lived carrier; unary RPCs carry a 35 s client ceiling
  surfacing `client/timeout` as a retryable error card.
- **Console continuity** — opening the console continues the machine's most
  recently updated session instead of forcing a new one.

### Fixed

- TOFU pin had readers but no writer: the pairing-time fingerprint was
  dropped, so the console, machine detail and renewal scheduler all built
  empty pin tables and were rejected by their own fail-closed TLS gate.
- Pairing sheet occluded by the IME: the inset padding read the page's
  `MediaQuery` instead of the sheet's, freezing the keyboard inset at sheet
  build time and pushing 解析链接 off-screen (fixed and regression-tested,
  portrait and landscape).
- A lost mux carrier permanently ended every logical stream (journal and
  `$events` never recovered); carrier loss now detaches and replays.
- The `4001` device-replaced close code was never read, so the immediate
  heal path was dead and every eviction degraded to exponential backoff.
- Unary engine RPCs had no client-side ceiling; a stalled tunnel spun the UI
  forever with no retry affordance.

First shippable build: the diagnostic stack, credential lifecycle and console
recovery paths are all real and machine-verified (see `docs/app-field-notes.md`
§6.13–§6.21).

### Added

- **Three-channel diagnostics** (D-107) — `app.log` / `crash.log` /
  `audit.log`, each with its own rolling quota, plus a channel switcher on the
  diagnostics page. Frame logging is aggregated (first 3 frames verbatim, then
  a per-2s summary by frame type): a 30s stream used to write ~6000 lines and
  evict the evidence; it now writes ~18.
- **Global crash capture** (D-107) — `FlutterError.onError` +
  `PlatformDispatcher.onError` + `runZonedGuarded`. Before this, a crash left
  the diagnostics page empty. The existing handler is still invoked, so the
  debug red screen survives.
- **Action log** (D-107) — 11 key actions and state transitions, written in
  release builds too.
- **Cold-start session restore** (D-109) — the console reopens *the session you
  were last reading*, not whichever one the engine touched most recently.
- **Terminal credential state** (D-110) — an expired credential no longer shows
  an infinite "reconnecting…"; it says it will not recover and offers the one
  action that works.
- **Credentials survive a backup** (D-113) — `allowBackup=false`,
  `fullBackupContent=false`, and a `dataExtractionRules` file that blocks both
  cloud backup and device-to-device transfer.
- **FLAG_SECURE** (D-113) — screenshots / screen recording of the console are
  blocked. Use `adb screencap` or the in-app diagnostics page to report issues.
- **Relay mints its own PSK** (D-112) — a missing (or still-insecure-default)
  PSK is generated, persisted to the data volume and printed as a path rather
  than refusing to boot. Minimum length 32.
- **Expired credentials can be re-armed** (D-111) — the relay allows exactly one
  path (`/dsh-remote/url-session`) to accept an expired-but-unrevoked,
  within-cap credential, so a missed renewal window is no longer terminal.
  The data plane stays locked for the same token.

### Fixed

- **Session titles survive a restart** (D-109) — `SessionTitleCache.load()` was
  only ever called from a test, so the cache was written but never rehydrated.
- **Golden baseline encoded a single moment** (D-108) — the "expired machine"
  fixture was minted from the wall clock while the render clock was frozen, so
  the stored baseline described a state that existed for a few hours on
  2026-10-03 and could never be reproduced again.
- **Two PSK entries in the engine profile** (D-113) — a second, dead
  `dsh-remote` block duplicated the live `agent-stock-remote` one; there is no
  plugin by that name in the harness.

### Changed

- **Persisted thinking is now viewable in history (D-088)** — the engine
  (0.2.0-rc.2+, `reasoningEffort > 0`) persists reasoning as a dedicated
  content block on `assistant/message`; the app now parses it, so past
  sessions show the「💭 已思考 · N 字」chip with tap-to-view instead of the
  thought vanishing when the durable bubble replaces the streaming row. The
  trajectory ledger records the reasoning character count per message
  (distinct from the billing-side `reasoningTokens`). Supersedes the D-069
  premise that journals carry no reasoning — re-verified against four live
  session journals.

- **Streaming thoughts default to collapsed (D-087)** — while the model is
  thinking, the block now renders as a compact pill「💭 思考中 · N 字」with a
  live character count instead of streaming the full reasoning onto the
  screen (mobile convention, aligned with the Claude / ChatGPT apps). Tap the
  pill to watch the live stream; tap again to collapse. When the answer text
  starts arriving the block auto-collapses to「💭 已思考 · N 字」as before,
  and a manual toggle still pins the state. Also fixes a latent wart where a
  pinned-collapsed block was force-expanded during streaming
  (`showBody = active || open` → `open`).

### Added

- **Logging system (D-077)** — app-wide `AppLog` facade with a sanitized
  rolling file sink (`app.log` + one `.old` generation, 256 KB each) in the
  app cache dir (excluded from backups by default; uninstalled with the app).
  Every line passes a single redaction chokepoint (`Bearer`/JWT/secret-kv →
  `[REDACTED]`, URL queries stripped); host names and session ids stay.
  The core network stack reports transport failures, TOFU verdicts and WS
  reconnects through a new zero-dependency `CoreLog` seam. Settings gains a
  「诊断日志」 page: monospace viewer, copy-all, OS share (share_plus) and a
  confirmed clear. Debug builds keep mirroring to logcat; release writes
  info-and-above to file only.
- New direct dependencies (both Flutter first-party, recorded per the
  dependency-whitelist discipline): `path_provider` (was already a transitive
  dep) and `share_plus`.
- **Plugin management (Host tab)** — the mounted-plugin list moved from the
  read-only `pluginInventory/list` to `pluginManager/listBundles`, and each
  installed bundle gets an enable switch (`pluginManager/setBundleEnabled`).
  Bundles the engine marks `management-required` show no switch; expanding a
  bundle lists its internal modules. A switch only flips after the engine
  confirms; `restart-required` results are labelled as such.
- **Agent preset picker** — new sessions can pick the agent preset (dsh web
  already had this; the app did not).
- **Session agent chip** — the console's context bar shows which preset a
  session belongs to, for the whole session.
- **Device smoke tests** (`integration_test/`) — three on-device structural
  checks (boot / tabs / diagnostics page / console composer), bilingual
  assertions. Note: `flutter test integration_test` uninstalls the app first,
  so it wipes pairing data — run it on a spare device only.

### Fixed

- **Sent messages could vanish (D-077)** — `session/prompt` dedupes on a
  client-minted `requestId`; the old sequence restarted at 0 with every app
  launch and collided with ids the engine had already processed, so the
  engine answered `ok` and dropped the message. Ids now carry a boot
  timestamp.
- **Approvals never reached the engine (D-078)** — two stacked causes: the
  `$events/result` args were wrapped in an extra `request` object the gateway
  rejects before descriptor dispatch, and re-opened `$events` generations
  invalidated the clientId used to answer. The args are now bare, the answer
  waits for the current generation's `ready`, retries once after a
  re-subscribe, and the card is only dismissed once the engine accepts.
- **Pending approvals not shown when entering a session (D-079)** — opening a
  session cleared the bubbles without re-subscribing `$events`, dropping
  already-delivered approvals until the next periodic re-open (up to 60 s).
- Plugin rows no longer crash on localized metadata (`{en, zh}` maps) and the
  host pane shows bundles (16) instead of 199 loader entries.
- Error cards abbreviate the account home directory to `~`.

Fixes for the two defects that made v1.0.0 unusable in the field.

### Fixed

- **release 包完全没有网络权限**（D-114）—— `INTERNET`（以及扫码配对要的
  `CAMERA`）只声明在 `src/debug` 与 `src/profile` 的 manifest 里，main（= release）
  没有。症状：release 包装得上、启动不崩、签名也对，但配对 / 控制台 / 更新检查一律
  `SocketException: Permission denied`。**只在 release 出现**——debug 包永远连得上，
  所以任何在 debug 上的验证（包括「启动没崩」「能装上」「签名正确」）都发现不了它。
- **更新检查拼错仓库路径**（D-114）—— `kSourceRepository` 是 `dsh-remote-relay`
  （只有仓库名、没有 owner），拼出 `/repos/dsh-remote-relay/...` ⇒ 404 ⇒「检查更新
  失败」。那条常量的注释还写着「remote 指向内网 Gitea」——那是过期信息，remote
  早就是 `github.com:T0x7/...`。**一条注释过期、代码照着它写错，比没有注释更糟。**
  首次写的守门方向也错了（只断言「不是完整 URL」，没断言「是不是 owner/repo」），
  于是照样放行；已改成指向真实失败形态。
