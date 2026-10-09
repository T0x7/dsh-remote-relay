# Contributing to dsh-remote-relay

Thanks for looking at this. It is a four-part system — relay server, tunnel
client, dsh plugin, Flutter app — and the tunnel itself lives in exactly one
place (`client/`), so most fixes touch one implementation rather than two.

## Prerequisites

- **Node ≥ 22** and **pnpm 9**
- **Flutter 3.49+ / Dart 3.13+** — only if you touch `app/`
- Docker — only if you touch `server/`

## One command

```bash
pnpm verify        # scripts/verify.sh — install → build → test, plus the
                   # client-bundle contract no unit test can see from source
```

It prints which layers actually ran. Specs whose prerequisites are unmet
**skip with a printed reason** rather than failing — so a green run with skips
is not the same as a green run without them. Read the `skip` lines.

## Layer by layer

```bash
pnpm -r build
pnpm -r test
pnpm -r typecheck

cd app && flutter analyze   # must be clean
cd app && flutter test
```

## Before you push

```bash
bash scripts/scan-secrets.sh          # tracked-tree leak scan
bash scripts/scan-secrets.selftest.sh # proves the guard still fires
```

`scan-secrets.sh` is not decorative — it covers public IPs, private hostnames,
credential-shaped assignments, personal home paths, and (with `--history`)
commit messages, which is where a real leak once rode in. If you add a rule,
add its fixture to the selftest; a guard that has never been observed to fail
is indistinguishable from a guard that does nothing.

If you touch `app/lib/l10n`, every key must exist in **both** locales:

```bash
python3 scripts/check-arb-keys.py
```

## Writing about the engine

The engine's `/api` contract is **hand-transcribed** in this repo, and that is
the single largest source of integration bugs here. If you touch anything that
speaks to the engine, read [`docs/engine-rpc-errata.md`](docs/engine-rpc-errata.md)
first — it records where the original transcription was wrong, and why a green
test suite did not catch it.

Rules that follow from that:

- **A contract claim needs a real engine behind it.** If a test asserts a wire
  shape, it must have been observed against a real engine, not just against our
  transcription of it.
- When you fix a shape, update the errata table in the same PR.

## Commit and PR conventions

- One concern per PR. The four parts of this system are easy to conflate and
  hard to review.
- Say **what** changed and **why** in the description; the diff already says
  how. If a change touches the wire protocol, say which side changed and why
  the two sides are still compatible.
- If you fixed something subtle, write down the trap. Most of the comments in
  this codebase are traps someone already fell into — keeping that habit is how
  the next person avoids repeating the debugging.

## Reporting bugs

Use the issue templates under `.github/ISSUE_TEMPLATE/`. For anything touching
security, **do not open a public issue** — see [`SECURITY.md`](SECURITY.md).