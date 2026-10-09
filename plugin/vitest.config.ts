import { defineConfig } from 'vitest/config'

/** Stand-in for the plugin's React surfaces, aliased for the non-rendering specs. */
const STUB = new URL('./tests/stubs/card.ts', import.meta.url).pathname
const MODEL = new URL('./src/client/', import.meta.url).pathname

/**
 * Standalone test config for the dsh remote plugin.
 *
 * Two halves, two needs:
 *  - Host half + capability drift guard: plain node, no DOM, no React.
 *  - Client half (gating CSS injection, auth/device watchdogs): needs a DOM
 *    (the specs pin `// @vitest-environment jsdom`) but NOT React.
 *
 * The client half stays plain .ts on purpose: the settings card and the relay
 * config form are .tsx modules it references for their registrations, so both
 * are aliased to stubs here and never rendered. Keeping the watchdog logic in
 * a JSX-free module is what lets these specs run without a React toolchain;
 * the real components are typechecked by `pnpm typecheck` and bundled by
 * `pnpm build` (tsdown emits the lazy-CJS browser half the dsh client module
 * system loads).
 */
export default defineConfig({
  test: {
    // e2e specs run here too: each one declares its own requirements (a built
    // artifact, an installed dsh) and skips with a message when unmet, so
    // `pnpm test` is green in a bare checkout and exhaustive in CI.
    include: ['tests/**/*.spec.ts', 'tests/**/*.e2e.ts'],
  },
  resolve: {
    alias: [
      // The card and the form view are JSX modules the client half references
      // for its registrations. The gating and watchdog specs exercise the
      // half's pure DOM logic and never render either component, so they are
      // stubbed. The form MODEL stays real: it has no dsh import by design, so
      // relay-config-form.spec.ts can exercise it directly.
      //
      // The stubs blind every spec in this run to the card↔form↔mount glue —
      // which is how a render condition on a prop nobody passed shipped
      // silently. That seam is pinned textually instead, by
      // tests/card-config-entry.spec.ts (no deps, runs in a bare checkout).
      { find: /^\.\/RemoteSettingsCard\.tsx$/, replacement: STUB },
      { find: /^\.\/RelayConfigForm\.tsx$/, replacement: STUB },
    ],
  },
})
