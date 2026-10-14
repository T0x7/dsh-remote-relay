# dsh_remote_app — the dsh remote-control app

Control a machine-bound [dsh](https://github.com/deepseek-ai/deepseek-harness)
engine from your phone. One Flutter codebase for iOS and Android.

Part of [dsh-remote-relay](../README.md): the relay gives you a public edge,
the client tunnels out from your machine, and **this app is the remote
control** in your pocket.

---

## What it does

- **Pairing** — scan the QR card from the dsh remote-control plugin, or paste
  the signed link. One pairing per machine, refreshed automatically inside its
  24 h window.
- **Conversations** — read a machine session, stream the assistant's reply,
  send prompts from the composer. Approvals and `ask_user_question` prompts
  arrive as interactive cards; answer them and the agent continues.
- **Sessions** — the machine's session list, searchable and switchable; new
  sessions created on the desktop appear here too.
- **Models & reasoning effort** — pick from the engine's own catalog, per
  session, or follow the deployment default.
- **Context ring** — live context pressure, token usage, cache hit rate.
- **Subagent teams** — read-only view of a parent session's child agents.
- **Jobs & host** — task cards for the open session; host panel with the
  session count and plugin inventory.
- **Lock screen** — a tap-to-unlock gate over the credential store, backed by
  the platform biometric APIs via `local_auth`. The platform channel sits behind
  a testable seam, so the three degradation paths (supported / not enrolled /
  unsupported) are each covered by tests, and the Settings toggle renders this
  device's real biometric capability rather than a hardcoded placeholder.

## App icon & name

The launcher icon is drawn once as SVG and cut to every platform size by
script — never edit the PNGs by hand:

- `assets/icon/app-icon.svg` — the master artwork ("session streams flowing
  into the device in your hand").
- `assets/icon/app-icon-foreground.svg` — the Android adaptive-icon foreground
  (glyph only, pre-scaled into the 66/108 safe zone).
- `assets/icon/render_masters.py` + headless Chrome produce the 2048px
  masters; `assets/icon/generate_icons.py` cuts all 31 PNGs (iOS 15,
  Android 5 densities × 3, Play Store 512).

The display name is **DSH Remote** — set in `android:label`,
`CFBundleDisplayName`, and the in-app `MaterialApp.title` / l10n strings.
PNG outputs are exempted from the repo-wide `*.png` ignore rule because they
are build inputs; a fresh clone without them has no icon at all.

## Security model

- **TOFU certificate pinning** — the relay's certificate is pinned at pairing
  and verified on every later connection; a changed certificate fails closed.
- **Credentials in the platform keystore** — Keychain / Keystore via
  `flutter_secure_storage`; nothing sensitive touches shared preferences.
- **Zero telemetry** — no analytics, no crash reporting, no third-party SDKs.
  Foreground-only; no push infrastructure.

## Architecture

```
app/
├── packages/dsh_remote_core/   # pure-Dart core: signed URLs, session clock,
│   │                           # pinned HTTP (TOFU), relay client, engine RPC,
│   │                           # mux carrier, error taxonomy
│   └── test/                   # 284 tests (a few need a live engine and
│                               #   skip with a printed reason without one)
├── lib/                        # the Flutter shell
│   ├── console/                # chat, sessions, jobs, host, models, context
│   ├── machines/               # machine list, detail, pairing flow
│   ├── services/               # renewal scheduler
│   └── data/                   # secure repository, pin seeding
└── test/                       # 374 tests (widgets, goldens, integration)
```

The engine contract is pinned by [../docs/engine-contract-m2.md]
(../docs/engine-contract-m2.md) and exercised by integration tests against a
live engine — unary control-plane calls over the shared `/api` channel, and
`session/follow`, `$events`, `job/list` streams multiplexed over one
`/api/remote.mux` socket.

## Getting the app onto your phone

**There is no prebuilt APK or IPA to download.** This project ships source, not
binaries — no app store, no release artifacts, no account service. You build it
yourself:

```bash
flutter pub get
flutter build apk                       # → build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

What the build needs:

| | requirement |
|---|---|
| Flutter / Dart | 3.49+ / 3.13+ |
| JDK | **17** — `sourceCompatibility` is pinned to `VERSION_17` |
| Android | **minSdk 24**, i.e. Android 7.0 or newer |
| iOS | Xcode **plus your own signing team** |

Three things that otherwise cost an afternoon:

- **`flutter build ios --no-codesign` produces nothing you can install.** It
  stops before signing, so no `.app` ever reaches a device. Budget for a
  provisioning profile — a free Apple ID gives a device-only install that
  expires and has to be re-signed.
- **The debug APK is ~144 MB** and mirrors logs to logcat. `--release` shrinks
  it and routes logs to the in-app 「诊断日志」 page instead
  (`Settings → 诊断日志`), which is also where you export them from.
- `adb install` does nothing until the phone has USB debugging authorised.

## Build & test

```bash
flutter pub get
flutter analyze        # must be clean
flutter test

flutter build apk --debug     # Android, fast iteration
flutter build apk             # Android, for a real device
```

## Layout compatibility

Portrait and landscape are both supported and pinned by
`test/landscape_layout_test.dart` (2400×1080 viewport, keyboard-inset cases
included).

## Status

M2 complete: pairing, conversations (streaming), approvals & questions,
sessions, models, context ring, subagent teams, jobs/host panel. Engine
tested against dsh `0.1.7-rc.2`. See [../docs/app-status.md]
(../docs/app-status.md) for the full E2E record.
