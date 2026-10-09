/**
 * Browser-half build for dsh-remote-relay-plugin.
 *
 * WHY THIS FILE EXISTS INSTEAD OF AN IMPORT: dsh's `clientBundle` tsdown preset
 * (packages/client/tsdown.client.ts inside a dsh checkout) is explicitly NOT
 * shipped in any published package — the settings-card cookbook states that a
 * package outside the dsh repository must reproduce this build itself. This file
 * is that reproduction, reduced to what this plugin actually uses.
 *
 * WHAT THE HOST EXPECTS: the dsh client module system concatenates several
 * plugins' `./client` files into one combo script and runs it as a plain
 * parser-blocking <script>. It is therefore not an ES module and may not have
 * top-level side effects. Executing it must only *register* a factory; every
 * module-body side effect (this plugin's fetch/WebSocket patches and CSS
 * injection included) has to live inside the factory and run at materialization.
 * The banner/footer below are that registration wrapper and are a hard contract,
 * not cosmetics — see docs/cookbook/adding-a-settings-card.md §5.
 *
 * The `id` below must stay byte-identical to package.json `name`: the runtime
 * matches it against the Loader row the bundle is attached to, and a mismatch
 * fails silently (the card simply never appears).
 *
 * @module dsh-remote-relay-plugin/tsdown.config
 */

import { readFileSync } from 'node:fs'
import { defineConfig } from 'tsdown'

/** Must equal package.json `name` — it is the registration key at runtime. */
const ID = 'dsh-remote-relay-plugin'

/**
 * Module specifiers the dsh shell seeds into its frozen module table. Mirrors
 * `PLATFORM_MODULES` in dsh's packages/client/web/src/platform.ts. They are
 * external by default and must NOT be repeated in dsh.client.external.
 */
const PLATFORM_MODULES = [
  'react',
  'react/jsx-runtime',
  'react-dom',
  'react-dom/client',
  '@deepseek-ai/cordis',
  '@deepseek-ai/dsh-client-store',
  '@deepseek-ai/dsh-client-ui-slots',
  '@deepseek-ai/dsh-client-ui-primitives',
  '@deepseek-ai/dsh-client-ui-dockkit',
] as const

const manifest = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf8'),
) as { dsh?: { client?: { external?: string[] } } }

/**
 * The package's own request list: platform baseline plus anything this manifest
 * declares. A `require()` the module table cannot answer is a guaranteed runtime
 * throw, so the rule is binary — requested specifiers stay `require()`s,
 * everything else inlines. This plugin's only non-platform import is
 * `qrcode-generator`, which therefore gets inlined.
 */
const requested = new Set<string>([
  ...PLATFORM_MODULES,
  ...(manifest.dsh?.client?.external ?? []),
])
const isRequested = (specifier: string): boolean => requested.has(specifier)

const mode = process.env.NODE_ENV ?? 'production'

export default defineConfig({
  name: `${ID}/client`,
  entry: { client: 'src/client/index.ts' },
  // The browser bundle lands beside the node half, which tsc already emitted
  // into the same lib/ directory; clean must stay off or it wipes that output.
  outDir: 'lib',
  // CJS is load-bearing, not a default: factory-form CJS makes a require cycle
  // throw instead of handing back half-initialised exports, and that loud
  // failure is the semantics the module system depends on.
  format: 'cjs',
  platform: 'browser',
  // Types ship from lib/types via tsc. Emitting dts here would wrap the
  // banner/footer below into a .d.cts and break parsing.
  dts: false,
  // The bundle is fetched outside the shell's module graph, so it must carry its
  // own map; it is served from /plugins/<package>/client.js.map.
  sourcemap: true,
  clean: false,
  deps: {
    neverBundle: isRequested,
    alwaysBundle: (specifier: string) => !isRequested(specifier),
  },
  inputOptions: {
    resolve: {
      conditionNames: [
        mode === 'development' ? 'development' : 'production',
        'browser',
        'import',
        'module',
        'default',
      ],
    },
  },
  // Inlined browser deps probe both process.env and import.meta.env; a CJS
  // output cannot carry import.meta, so both are substituted here or the factory
  // throws ReferenceError at boot. Keep the bare `import.meta.env` key next to
  // the precise MODE key — code probes truthiness first.
  define: {
    'process.env.NODE_ENV': JSON.stringify(mode),
    'import.meta.env.MODE': JSON.stringify(mode),
    'import.meta.env': JSON.stringify({ MODE: mode }),
  },
  outputOptions: {
    entryFileNames: 'client.js',
    chunkFileNames: 'client.[name].js',
    sourcemapExcludeSources: false,
    // The registration wrapper. `factory: (require) => {` opens; the footer
    // closes and returns the exports. Top-level code does nothing else.
    banner: (chunk) =>
      `window.__ModuleLoader__.load({ id: ${JSON.stringify(ID)}, `
      + `${chunk.isEntry ? '' : `chunk: ${JSON.stringify(chunk.fileName)}, `}factory: (require) => {`,
    footer: 'return module.exports; } });',
    intro: 'var module = { exports: {} }; var exports = module.exports;',
  },
})
