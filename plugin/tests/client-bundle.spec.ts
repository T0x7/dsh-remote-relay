/**
 * Browser-half artifact test: the BUILT lib/client.js, as the dsh client
 * module system will actually load it.
 *
 * The dsh client module system concatenates several plugins' `./client` files
 * into one combo script and runs it as a plain parser-blocking <script>. It is
 * therefore not an ES module and may not have top-level side effects:
 * executing it may only REGISTER a factory, and every module-body side effect
 * must run when that factory is materialised
 * (packages/client/modules/README.md, "Lazy-CJS model").
 *
 * This is the contract the plugin's own tsdown build reproduces (the
 * `clientBundle` preset is not published, so an out-of-repo plugin rebuilds it —
 * docs/cookbook/adding-a-settings-card.md §5). Every unit spec in this repo
 * tests SOURCE modules; a source test cannot catch a banner/footer typo, a
 * dropped externals rule, or a missing `id` — those only exist in the artifact.
 *
 * The fixture page mirrors the harness's own browser test
 * (packages/experimental/inspector/tests/client-browser.e2e.ts): a fake
 * `__ModuleLoader__` that captures the registration, then a materialisation
 * call that runs the factory with a require that answers only what the package
 * legitimately requests.
 *
 * RUN REQUIREMENTS — needs `pnpm build` to have produced lib/client.js. It skips
 * with a message when the artifact is absent, so a source-only checkout stays
 * green; CI builds before testing, so it runs there for real.
 */
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const bundlePath = resolve(packageRoot, 'lib/client.js')
const manifest = JSON.parse(readFileSync(resolve(packageRoot, 'package.json'), 'utf8')) as {
  name: string
  exports: { './client': { default: string } }
  /** Platform modules this bundle may require — the loader supplies exactly these. */
  dsh: { client: { inject: readonly string[] } }
}

const built = existsSync(bundlePath)
if (!built) {
  // eslint-disable-next-line no-console
  console.warn(
    '[client-bundle] skipped: lib/client.js not found (run `pnpm build` in plugin/ to exercise these specs)',
  )
}

/**
 * Execute the artifact the way the combo script does: a plain script whose only
 * job is to hand the registration to a loader stand-in.
 * @returns the captured ClientBundleRegistration.
 */
function executeBundle(): { id: string; factory?: (require: (specifier: string) => unknown) => Record<string, unknown> } {
  const source = readFileSync(bundlePath, 'utf8')
  let registration: { id: string; factory?: (require: (specifier: string) => unknown) => Record<string, unknown> } | undefined
  const loader = { load: (submitted: typeof registration) => { registration = submitted } }
  // The bundle is a classic script, not a module: run it with no import map,
  // no top-level await, and only the two globals the host predefines.
  const run = new Function('window', 'globalThis', `${source}\n//# sourceURL=client.js`)
  run({ __ModuleLoader__: loader }, { __ModuleLoader__: loader })
  if (registration === undefined) throw new Error('bundle did not register a factory through window.__ModuleLoader__.load')
  return registration
}

describe.skipIf(!built)('browser half — built lazy-CJS artifact', () => {
  it('registers exactly one factory, under this package name', () => {
    const registration = executeBundle()
    expect(registration.id).toBe(manifest.name)
  })

  it('registers with no chunk field — this is the entry, not a generated chunk', () => {
    const registration = executeBundle()
    // A `chunk:` on the entry means the banner misfired; the runtime keys the
    // registration by id and would look for a file that does not exist.
    expect(registration.factory).toBeTypeOf('function')
  })

  it('exposes apply + inject so the client module system can mount it', () => {
    const registration = executeBundle()
    const exports = registration.factory?.(
      answerOnly(['react', 'react/jsx-runtime', '@deepseek-ai/cordis', ...manifest.dsh.client.inject]),
    )
    expect(exports).toMatchObject({ inject: expect.anything() })
    expect(exports?.apply).toBeTypeOf('function')
  })

  it('requires only platform modules the manifest declares in dsh.client.inject', () => {
    // The first real build corrected this rule's original wording ("dsh
    // client packages are type-only, never required"): constructing the relay
    // form model needs SettingsFormModel as a VALUE from ui-primitives, which
    // is exactly what dsh.client.inject declares — the loader's module table
    // answers requires for declared modules and only those. An UNDECLARED
    // @deepseek-ai/dsh-client-* require is the real bug: the loader cannot
    // answer it, so the factory dies at mount time.
    const source = readFileSync(bundlePath, 'utf8')
    const requires = [...source.matchAll(/require\(["']([^"']+)["']\)/g)].map((match) => match[1] ?? '')
    const declared = new Set(manifest.dsh.client.inject)
    const undeclared = requires.filter(
      (specifier) => specifier.startsWith('@deepseek-ai/') && !declared.has(specifier),
    )
    expect(undeclared).toEqual([])
  })

  it('keeps every dsh specifier out of the bundle body', () => {
    // A dsh package that got inlined (rather than requested from the loader's
    // module table) is the purity-gate failure this build has to avoid.
    const source = readFileSync(bundlePath, 'utf8')
    expect(source).not.toMatch(/from\s*["']@deepseek-ai\/dsh-client-/)
  })

  it('is a classic script, not an ES module (the host concatenates them)', () => {
    const source = readFileSync(bundlePath, 'utf8')
    expect(source).not.toMatch(/^\s*export\s/m)
    expect(source).not.toMatch(/^\s*import\s+[^(]/m)
  })
})

/**
 * A require that answers only the platform baseline, and throws for anything
 * else — mirroring the runtime, where an unanswered require is a loud throw
 * rather than a silent undefined.
 */
function answerOnly(allowed: readonly string[]): (specifier: string) => unknown {
  return (specifier: string): unknown => {
    if (!allowed.includes(specifier)) {
      throw new Error(`Unexpected Client bundle dependency ${specifier}`)
    }
    // The baseline members are only reached for their values by React itself;
    // a shape-free stand-in is enough to materialise the plugin's own body.
    return specifier === '@deepseek-ai/cordis' ? { Context: { is: () => false } } : {}
  }
}
