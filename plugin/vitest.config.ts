import { defineConfig } from 'vitest/config'
import { createRequire } from 'node:module'
import path from 'node:path'

/** Stand-in for the plugin's React surfaces, aliased for the non-rendering specs. */
const STUB = new URL('./tests/stubs/card.ts', import.meta.url).pathname
const MODEL = new URL('./src/client/', import.meta.url).pathname

/**
 * The REAL primitives build for the render spec.
 *
 * form-render.spec.tsx renders RelayConfigForm against the published
 * SettingsFormModel instead of a hand-written double. The npm tarball of
 * @deepseek-ai/dsh-client-ui-primitives declares every library it bundles as
 * a peerDependency, so importing it from a plugin checkout would drag in a
 * dozen unrelated devDeps. The engine vendor ships the same version (rc.2)
 * with its dependency tree resolved, so the alias points there; a checkout on
 * a machine without the vendor tree skips the render spec instead of failing.
 */
const require_ = createRequire(import.meta.url)
let PRIMITIVES_LIB: string | undefined
try {
  PRIMITIVES_LIB = require_.resolve('@deepseek-ai/dsh-client-ui-primitives/package.json')
} catch {
  PRIMITIVES_LIB = undefined
}
// Where the engine's packaged vendor tree lives.
//
// This was a literal `/Users/<name>/Container/…` path, which put a real
// username and a private sibling checkout's layout into a public repository.
// `DSH_VENDOR_TREE` now takes precedence; the fallback resolves the sibling
// checkout relative to this repo instead of hardcoding a home directory, so it
// works with no setup on a machine that has one and is simply absent on a
// machine that does not — in which case the render spec skips itself, exactly
// as it does in CI, which has no vendor tree either.
const SIBLING = new URL('../../', import.meta.url).pathname
const VENDOR_TREE = process.env.DSH_VENDOR_TREE
  ?? SIBLING + 'agent-stock/apps/agent-stock-desktop/dist/mac-arm64/AgentStock.app/Contents/Resources/engine/vendor/deepseek-harness'
const VENDOR_PRIMITIVES = VENDOR_TREE + '/packages/client/ui-primitives'
// The vendor build resolves react against ITS OWN node_modules; the spec's
// react-dom resolves against the plugin's. Two React copies = "invalid hook
// call". Aliasing react and react/jsx-runtime onto the vendor copy keeps one
// instance across the whole render.
const VENDOR_REACT_CANDIDATE = VENDOR_TREE + '/node_modules/.pnpm/react@18.3.1/node_modules/react'
const VENDOR_REACT_DOM_CANDIDATE = VENDOR_TREE + '/node_modules/.pnpm/react-dom@18.3.1_react@18.3.1/node_modules/react-dom'
const VENDOR_REACT_LIB = (() => {
  try { require_.resolve(VENDOR_REACT_CANDIDATE + '/package.json'); return VENDOR_REACT_CANDIDATE } catch { return undefined }
})()
const VENDOR_REACT_DOM_LIB = (() => {
  try { require_.resolve(VENDOR_REACT_DOM_CANDIDATE + '/package.json'); return VENDOR_REACT_DOM_CANDIDATE } catch { return undefined }
})()
const hasVendorPrimitives = (() => {
  try { return require_.resolve(VENDOR_PRIMITIVES + '/package.json') !== undefined } catch { return false }
})()

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
    include: ['tests/**/*.spec.ts', 'tests/**/*.spec.tsx', 'tests/**/*.e2e.ts'],
    // The render spec needs the vendor tree (see the alias block below). It
    // cannot skip itself: its import of the primitives package is a literal
    // specifier, which Vite resolves during transform — so on a checkout
    // without the vendor tree the first undeclared external it pulls in
    // (`simple-icons`) kills the file at load, and a whole-file failure is not
    // a skip. This job therefore did not run this spec, it failed on it, and
    // that only stayed hidden for as long as the job died earlier at install.
    //
    // Exclude it here rather than stubbing the import: a stub would make the
    // controlled-input assertion pass against a double, which is exactly the
    // fake-greener-than-production trap that spec exists to close. Skipping is
    // honest about the coverage this environment does not have.
    //
    // `exclude` replaces Vitest's defaults, so they are restated here.
    exclude: hasVendorPrimitives
      ? ['**/node_modules/**', '**/dist/**', '**/cypress/**', '**/.{idea,git,cache,output,temp}/**']
      : ['**/node_modules/**', '**/dist/**', '**/cypress/**', '**/.{idea,git,cache,output,temp}/**',
         'tests/form-render.spec.tsx'],
  },
  resolve: {
    alias: [
      // The render spec needs the REAL primitives. Prefer the local install
      // when its peer tree is satisfied; otherwise the engine vendor ships the
      // same rc.2 build with a resolved tree. form-render.spec.tsx skips
      // itself when neither exists.
      ...(hasVendorPrimitives && VENDOR_REACT_LIB && VENDOR_REACT_DOM_LIB
        ? [
            { find: /^react$/, replacement: path.join(VENDOR_REACT_LIB!, 'index.js') },
            { find: /^react\/jsx-runtime$/, replacement: path.join(VENDOR_REACT_LIB!, 'jsx-runtime.js') },
            { find: /^react-dom$/, replacement: path.join(VENDOR_REACT_DOM_LIB!, 'index.js') },
            { find: /^react-dom\/client$/, replacement: path.join(VENDOR_REACT_DOM_LIB!, 'client.js') },
          ]
        : []),
      ...(hasVendorPrimitives
        ? [{ find: /^@deepseek-ai\/dsh-client-ui-primitives$/, replacement: VENDOR_PRIMITIVES }]
        : []),
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
      // form-render.spec.tsx is the render-level half of that seam: the two
      // aliases above must NOT catch the spec's own direct import, which is
      // absolute and therefore unmatched by the relative patterns below.
      { find: /^\.\/RemoteSettingsCard\.tsx$/, replacement: STUB },
      { find: /^\.\/RelayConfigForm\.tsx$/, replacement: STUB },
    ],
  },
})
