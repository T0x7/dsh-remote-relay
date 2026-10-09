# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for a security report.** A public issue
puts the flaw in front of everyone who can reach your relay.

Instead, use GitHub's private reporting on this repository
("Security" → "Report a vulnerability"). If that is unavailable to you, open a
regular issue containing **only** a description of the class of the bug and no
exploit detail, and ask for a private channel in that issue.

Please include:

- what an attacker can achieve (read sessions? write? reach the engine's
  privileged surface?),
- the version/commit you tested,
- the configuration that matters (relay PSK set? `RELAY_PUBLIC_HOST` set?
  `--trusted-host` on the engine?).

We aim to acknowledge a report within a few days and to keep you updated while
it is being fixed. Credit is yours unless you ask otherwise.

## Threat model, in one paragraph

This system exists so a machine-bound dsh engine can be reached from a phone
**without being exposed to the internet**. Two gates stand between the public
internet and the engine, and the design assumes **either one alone is not
enough**:

1. **Engine gate** — dsh binds loopback and serves `/api` only to requests
   whose `Host` is loopback or a `--trusted-host` entry; the PRIVILEGED
   methods (`settings.*`, `credentials.*`, `host.*`, …) stay loopback-only.
2. **Relay gate** — the client pins the trusted authority into every bridged
   request, and the relay requires credentials (signed-URL query, pairing
   cookie, or a `Bearer` session token) on every path except its own
   health/PSK endpoints.

The machine dials **out** over the tunnel. Nothing listens inbound.

## What is deliberately fail-closed

These behaviours are load-bearing. Please do not "helpfully" relax them:

- Production **refuses to boot** on the insecure default PSK or a missing
  `RELAY_PUBLIC_HOST`.
- An expired signed URL fails closed rather than degrading to open.
- A **changed relay certificate fails closed** (TOFU pinning, fixed at pairing).
- A forgotten PSK override fails at the relay rather than opening a channel.
- Readonly/query fences on proxied engine calls.

## Handling secrets

- `RELAY_PSK` is the root secret. Rotate it if it is ever exposed; rotating it
  invalidates signed URLs and pairings, so plan for re-pairing.
- Session secrets live in `server/data/relay-state.db` — treat that volume
  like a secret store. It also holds the append-only audit log.
- Client pairings live in `~/.dsh-remote-relay/` (chmod 600).
- Never commit `.env`, keys, or certificates. `.gitignore` covers `.env` and
  `*.pem`, and `scripts/scan-secrets.sh` fails the build if one slips in.