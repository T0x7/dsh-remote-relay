/**
 * Stubs for the settings-card JSX modules.
 *
 * `src/client/index.ts` imports the card for the registrations it hands to the
 * dsh slots, and the card imports the config form. The specs that run in this
 * repo (gating CSS injection, the auth/device watchdogs) exercise pure DOM
 * logic and never render either component, so both are aliased here and the
 * real modules stay out of a React-less test run.
 *
 * The value semantics of the form live in `relay-config-model.ts` (plain .ts,
 * NOT stubbed) and are covered directly by relay-config-form.spec.ts.
 *
 * The real components are typechecked by `pnpm typecheck` and bundled by
 * `pnpm build` (tsdown emits the lazy-CJS browser half the dsh client module
 * system loads).
 */
export const RemoteSettingsCard = undefined as unknown as never
export default RemoteSettingsCard

/** Config form stub — the card references it; no spec renders it. */
export const RelayConfigForm = undefined as unknown as never

/** index.ts imports this from the form module; stubbed for the same reason. */
export const createRelayForm = undefined as unknown as never
