## What and why

<!-- The diff already shows how. Say what changed and why it is the right
     shape. If an alternative was rejected, one line on why is usually enough. -->

## Which part of the system

<!-- server / client / plugin / app / docs — or a cross-cutting change. -->

Closes #

## Verification

- [ ] `pnpm verify` (or the affected layer) run locally
- [ ] `bash scripts/scan-secrets.sh` clean
- [ ] `python3 scripts/check-arb-keys.py` clean (if `app/lib/l10n` touched)
- [ ] App: `flutter analyze` clean, `flutter test` green (if `app/` touched)

Paste the interesting part of the output. If a layer **skipped**, say so — a
green run with skips is not the same as a green run.

## Wire protocol / engine contract

<!-- Only if this touches what goes over the tunnel or how we speak to the
     engine. -->

- [ ] Either side only (describe which, and why the other still works)
- [ ] Both sides together (the change is compatible in both directions)
- [ ] Not applicable

If you changed a request/response shape, state whether you observed it against
a **real engine** — not just against our transcription of one. Most integration
bugs in this repo came from trusting the transcription, and
`docs/engine-rpc-errata.md` exists because of it. If you corrected a shape,
please add the entry to that table in this same PR.

## Traps

<!-- Optional, and the most valuable part. If you lost an hour to something
     non-obvious — an ordering assumption, a lifecycle edge, a contract that
     looked fine — write it down. Most comments in this codebase are traps
     someone already fell into; this is how the next person avoids repeating
     the debugging. -->