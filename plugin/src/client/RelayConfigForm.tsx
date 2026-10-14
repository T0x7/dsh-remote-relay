/**
 * Relay connection form — the configuration entry point inside the dsh UI.
 *
 * WHY IT EXISTS: the pairing card can only report a live tunnel. Without a
 * form, `relay_url` / `psk` / `enabled` could only be set by hand-editing the
 * profile's cordis.patch.yml — exactly the step a self-hosted operator should
 * not have to take.
 *
 * Rendering only: every value rule, the staging model and the save semantics
 * live in ./relay-config-model.ts, which the unit specs import directly. This
 * module is the dsh-primitives view of that model.
 *
 * The dsh primitives used here are the ones the official settings pages use
 * (SettingsForm / SettingsValueField / SettingsSecretField). Note that
 * `ConfigField` is NOT one of them: it exists in ui-primitives but is not
 * exported from its index and has no consumer in the harness — importing it
 * would not compile.
 */
import {
  SettingsForm,
  SettingsFormModel,
  SettingsSecretField,
  SettingsValueField,
  type SettingsSecretSpec,
} from '@deepseek-ai/dsh-client-ui-primitives'
import { useMemo, useSyncExternalStore } from 'react'
import type { ConfigForm } from '@deepseek-ai/dsh-client-ui-settings/client'
import {
  ENTRY_ID,
  RELAY_FIELD_SPECS,
  RELAY_SECRET_FIELDS,
  secretConfigured,
  type RelayConfigValues,
  type SecretSlot,
} from './relay-config-model.ts'


/**
 * Build the staging model over one entry's shared Host form.
 * @param form - `ctx.configForms.get(ENTRY_ID)`.
 * @returns the model the card renders and saves from.
 */
export function createRelayForm(form: ConfigForm<RelayConfigValues>): SettingsFormModel<RelayConfigValues> {
  // Write-only controls for the two role('secret') fields: the draft is always
  // blank, and a blank draft writes nothing.
  const secrets: SettingsSecretSpec[] = RELAY_SECRET_FIELDS.map((field) => ({
    field,
    write: async (text: string): Promise<boolean> => {
      const value = text.trim()
      if (value === '') return true
      return form.set(field, value)
    },
  }))

  return new SettingsFormModel<RelayConfigValues>(
    // ConfigForm's read/mutate face is structurally the SettingsFormScope the
    // primitives layer consumes; the cast names that adaptation explicitly.
    form as unknown as ConstructorParameters<typeof SettingsFormModel<RelayConfigValues>>[0],
    // The field rules are plain objects that satisfy the dsh spec shape.
    [...RELAY_FIELD_SPECS],
    secrets,
  )
}

/** Localised chrome for the form frame (field copy is inline; the card's own copy lives in locales.ts). */
const FORM_LABELS = {
  unavailable: '此页面无法写入配置：dsh 在非回环页面不持久化设置。请在本机页面完成配置。',
  readOnly: '只读',
  saveFailed: '保存未生效，请检查取值是否合法。草稿已保留，可修改后重试。',
  save: '保存',
  saving: '保存中…',
}

/**
 * The relay connection form: one control per Config field plus the two
 * write-only secret fields. Nothing reaches the Host until Save.
 *
 * v3.282 — SUBSCRIBE, do not poll-read. This component used to call
 * `model.shell()` / `model.field()` straight from render without binding to
 * the model, so a keystroke changed the model but nothing re-rendered: React
 * reset the controlled input to its last-rendered text, the typed character
 * vanished, and it only reappeared when the parent's one-second tick happened
 * to repaint the subtree. The primitives' snapshot store flushes synchronously
 * for exactly this reason ("controlled inputs need same-tick echo"); `bind()`
 * is the documented way onto that flush, and the official cards all go through
 * it (see ui-settings-shell/shell-card-controller.ts).
 *
 * `useSyncExternalStore` subscribes this component to that projection, so the
 * echo is same-tick, the save button's disabled state tracks the drafts
 * instead of the last repaint, and the parent's per-second tick is no longer
 * the thing keeping the form alive.
 *
 * @param props - the staging model, and this entry's secret slots as the Host
 * reports them (existence only — the values never leave the Host).
 * @returns the form frame.
 */
/** One immutable projection of the form — what the controls render from. */
interface RelayFormProjection {
  shell: ReturnType<SettingsFormModel<RelayConfigValues>['shell']>
  fields: {
    enabled: ReturnType<SettingsFormModel<RelayConfigValues>['field']>
    relay_url: ReturnType<SettingsFormModel<RelayConfigValues>['field']>
    upstream_host: ReturnType<SettingsFormModel<RelayConfigValues>['field']>
    upstream_port: ReturnType<SettingsFormModel<RelayConfigValues>['field']>
  }
}

export function RelayConfigForm(props: {
  model: SettingsFormModel<RelayConfigValues>
  secrets: readonly SecretSlot[] | undefined
}) {
  const { model, secrets } = props

  // Built once per model: bind() registers a listener for the lifetime of the
  // store, so it must not re-run per render.
  const store = useMemo(
    () => model.bind(() => ({
      shell: model.shell(),
      fields: {
        enabled: model.field('enabled'),
        relay_url: model.field('relay_url'),
        upstream_host: model.field('upstream_host'),
        upstream_port: model.field('upstream_port'),
      },
    })),
    [model],
  )
  const state = useSyncExternalStore<RelayFormProjection>(
    store.subscribe as (onStoreChange: () => void) => () => void,
    () => store.getSnapshot() as RelayFormProjection,
  )
  const actions = model.actions()
  const { shell } = state
  const disabled = !shell.writable
  const pskConfigured = secretConfigured(secrets, 'psk')
  const engineTokenConfigured = secretConfigured(secrets, 'engine_token')

  return (
    <SettingsForm labels={FORM_LABELS} state={shell} onSave={actions.save} onDiscard={actions.discard}>
      <SettingsValueField
        id="plugin-config-remote-enabled"
        label="启用出站中继隧道 (enabled)"
        hint="关闭时不建立任何公网通道；开启后引擎启动即拨号中继。"
        overriddenLabel="已自定义"
        resetLabel="恢复默认"
        invalidLabel="只接受 true 或 false"
        disabled={disabled}
        {...state.fields.enabled}
        onEdit={(text) => { actions.edit('enabled', text) }}
        onReset={() => { actions.resetField('enabled') }}
      />
      <SettingsValueField
        id="plugin-config-remote-relay-url"
        label="中继地址 (relay_url)"
        hint="你部署在公网 VPS 上的 relay 地址，例如 https://relay.example.com"
        placeholder="https://relay.example.com"
        overriddenLabel="已自定义"
        resetLabel="恢复默认"
        invalidLabel="取值不合法"
        disabled={disabled}
        {...state.fields.relay_url}
        onEdit={(text) => { actions.edit('relay_url', text) }}
        onReset={() => { actions.resetField('relay_url') }}
      />
      <SettingsSecretField
        id="plugin-config-remote-psk"
        label="共享密钥 (psk)"
        hint="必须与 VPS 的 RELAY_PSK 一致。出于安全不会回显，留空表示不修改。"
        configured={pskConfigured}
        stateLabel="已设置（不回显）"
        disabled={disabled}
        text=""
        onEdit={(text) => { actions.edit('psk', text) }}
      />
      <SettingsValueField
        id="plugin-config-remote-upstream-host"
        label="本机引擎地址 (upstream_host)"
        hint="数据面转发到的本机 dsh 引擎，一般保持默认。"
        placeholder="127.0.0.1"
        overriddenLabel="已自定义"
        resetLabel="恢复默认"
        invalidLabel="取值不合法"
        disabled={disabled}
        {...state.fields.upstream_host}
        onEdit={(text) => { actions.edit('upstream_host', text) }}
        onReset={() => { actions.resetField('upstream_host') }}
      />
      <SettingsValueField
        id="plugin-config-remote-upstream-port"
        label="本机引擎端口 (upstream_port)"
        hint="1–65535 之间的整数，一般保持默认 3080。"
        numeric
        overriddenLabel="已自定义"
        resetLabel="恢复默认"
        invalidLabel="请输入 1–65535 的整数"
        disabled={disabled}
        {...state.fields.upstream_port}
        onEdit={(text) => { actions.edit('upstream_port', text) }}
        onReset={() => { actions.resetField('upstream_port') }}
      />
      <SettingsSecretField
        id="plugin-config-remote-engine-token"
        label="引擎绑定令牌 (engine_token)"
        hint="仅当本机引擎启用了 bind token 时填写。留空表示不修改。"
        configured={engineTokenConfigured}
        stateLabel="已设置（不回显）"
        disabled={disabled}
        text=""
        onEdit={(text) => { actions.edit('engine_token', text) }}
      />
    </SettingsForm>
  )
}
