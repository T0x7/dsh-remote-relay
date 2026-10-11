# Changelog

All notable changes to `dsh_remote_app` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

## [0.1.0] — 2026-10-03

First internal milestone (M2 complete, engine `0.1.7-rc.2`).

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
