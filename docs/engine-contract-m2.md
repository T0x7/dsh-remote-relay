# dsh 引擎 Remote 线契约（M2 控制台最小集）

来源：`/opt/homebrew/lib/node_modules/@deepseek-ai/dsh-root/` — `@deepseek-ai/dsh-root` **0.1.7-rc.2**（`package.json:3`）。
本文件所有字段名均为 wire 上的 TS 原名。凡未在源码中找到的路由，明确写「0.1.7-rc.2 无此路由」。

术语：**RPC = HTTP 单播**；**STREAM = mux WebSocket**；**EVENT = `$events` 逻辑流**。

---

## 0. 传输底座

### 0.1 路由形态

- 共享通道前缀 `API_PATH = '/api'`，`/api` 与 `/api/<anything>` 全归它（`client/connection/src/api-path.ts:7`）
- 端点 = `` `${namespace}/${method}` ``，**斜杠分隔，不是点**（`api/gateway/src/index.ts:1370-1372`）
- 端点必须恰好两段，段内字符集 `^[A-Za-z0-9_$.-]+$`（`api/gateway/src/index.ts:1114-1123`、`client/connection/src/rpc-host.ts:280-289`）
- Host 在 `/api` 上装拦截器（`api/gateway/src/index.ts:232-238`）

实际路径：`POST /api/session/list`、`POST /api/session/prompt`、`POST /api/session/page`、`POST /api/$events/result`。

> **纠错**：`/api/session.list` / `/api/sessions.list` 两种点号形态在本版本**不存在**。`sessions` 只是客户端本地服务名（`api/session-controller/src/client/sessions/service.ts`），不是 Remote namespace。全仓库无 `@Remote('export')`；**`session.export` 在 0.1.7-rc.2 无此路由**。

已注册 namespace（`super(ctx, key, { namespace })`）：

`session`（`api/session-controller/src/index.ts:136`）· `skills`（`skill-catalog.ts:24`）· `fileReferences`（`file-references.ts:22`）· `job`（`api/job-controller/src/index.ts:59`）· `subagents`（`subagent/subagent/src/index.ts:215`）· `workspace` / `directoryPicker`（`api/workspace-controller/src/index.ts:68`、`:46`）· `workspaceFiles`（`api/workspace-files/src/index.ts:200`）· `settings` / `credentials`（`api/settings-controller/src/index.ts:86`、`:70`）· `terminal`（`:102`）· `account`（`api/account-controller/src/index.ts:13`）· `llm`（`llm/llm/src/index.ts:351`）· `goals`（`goal/goal/src/index.ts:251`）· `commands`（`interaction/commands/src/index.ts:277`）· `permissionPresets`（`interaction/permission-presets/src/index.ts:208`）· `schedule`（`schedule/schedule/src/index.ts:121`）· `agentPresets`（`preset/agent-preset-registry/src/index.ts:64`）· `fileUploads`（`client/file-upload/src/index.ts:65`）。

`todo` **无 Remote namespace**（`packages/todo/tool-todo` 只有事件 + 投影）。`context` 域无 Remote 路由。

### 0.2 HTTP 单播（RPC）完整请求/响应

请求（`client/connection/src/rpc.ts:80-85`，zod 见 `rpc-schema.ts:35-40`）：

```json
{
  "type": "client-request",
  "rpcId": "<uuid v4, 客户端自铸>",
  "method": "session/prompt",
  "payload": { "args": { "<wire 参数名>": ..., ... } }
}
```

- **方法** `POST`，路由 = `` `${channel}/${endpoint}`.slice(1) `` → `api/session/prompt`
- **头** `content-type: application/json`（`client/connection/src/client/rpc.ts:48-57`）
- **`payload` 必须恰好一个键 `args`，且 `args` 是 plain object**（`api/gateway/src/index.ts:1125-1131`）
- **`args` 的键 = 端点声明的业务参数名，逐字匹配，多一个少一个都报 `gateway/arguments-invalid`**（`api/gateway/src/index.ts:1465-1491`）。`signal` 是最后一个参数且不上线。
- 客户端铸 envelope：`api/gateway/src/client/index.ts:445` — `connection.rpc.call('/api', endpoint, { args: prepared.args }, signal)`

响应（`client/connection/src/rpc.ts:88-92`，zod 见 `rpc-schema.ts:43-47`）：

```json
{ "type": "server-response", "rpcId": "<与请求相同>", "result": { "ok": true,  "value": <业务值> } }
{ "type": "server-response", "rpcId": "<与请求相同>", "result": { "ok": false, "error": { "code": "...", "message": "...", "details": { } } } }
```

- `error` 三键**精确且全部必填**：`code: string`、`message: string`、`details: object`
  出处：`client/connection/src/rpc.ts:19-23`、`rpc-schema.ts:10-14`、`client/rpc.ts:160-168`
- `ok: true` 时 `value` **可能缺席**（void 业务方法）→ `api/gateway/src/index.ts:675-679`
- `rpcId` 不匹配 → 客户端抛错（`client/rpc.ts:66-68`）
- 二进制结果走 `multipart/form-data`（`result` 里 `null` 占位 + `attachments[]` + `metadata` 段），**本控制台最小集不涉及**

### 0.3 流式 RPC（mux WebSocket）

- WS 路径 `REMOTE_STREAM_MUX_PATH = '/api/remote.mux'`（`api/gateway/src/stream-protocol.ts:7`）
- URL 由 `document.baseURI` 解析，`https:` → `wss:`，可被 `globalThis.__DSH_TRANSPORT__.streamBaseUrl` 覆盖（`api/gateway/src/client/stream-client.ts:472-480`）
- 升级前走同一套 Host/Origin + 浏览器鉴权（401/403 直接拒升级）（`api/gateway/src/index.ts:252-259`、`client/connection/src/rpc-host.ts:104-113`）
- 只接受文本帧；收到二进制 → `close(1003)`；上行解析失败 → `close(1008)`（`api/gateway/src/stream-server.ts:150-160`）
- Host 侧 ping/pong 心跳，漏 2 次 `terminate()`（`api/gateway/src/stream-server.ts:40`、`:104-124`）
- 客户端开流：`connection.rpc.open('/api', endpoint, payload, signal, uplink)`，`payload = { args }`（`api/gateway/src/client/index.ts:229`、`:477-482`）

**上行帧**（`stream-protocol.ts:235-244`，解析与精确键校验 `:264-286`）：

```jsonc
{ "type": "open",   "streamId": "<uuid>", "endpoint": "session/follow", "payload": { "args": { ... } } }
{ "type": "item",   "streamId": "<uuid>", "value": <任意 JSON> }   // value 可缺席
{ "type": "end",    "streamId": "<uuid>" }                        // 上行半关闭
{ "type": "cancel", "streamId": "<uuid>" }                        // 取消逻辑流
```

**下行帧**（`stream-protocol.ts:254-257`，精确键校验 `:293-315`）：

```jsonc
{ "type": "item",  "streamId": "<uuid>", "value": <AsyncIterable 每次 yield 的值> }
{ "type": "error", "streamId": "<uuid>", "error": { "code": "...", "message": "...", "details": { } } }
{ "type": "end",   "streamId": "<uuid>" }
```

- `error.error` 是**精确三键、全部必填**：`code: string` / `message: string` / `details: object`（`stream-protocol.ts:247-251`、`:303-311`）
- 同一 `streamId` 重复 `open` 是唯一会关闭 socket 的协议违规（`stream-server.ts:177-179`、`:158`）
- STREAM 端点**不可**用 HTTP 单播调用，报 `gateway/signature-invalid`（`api/gateway/src/index.ts:350-356`）；反之亦然（`:384-391`）
- 上行 inbox 字节上限 `streamInboxBytes`（默认见 `api/gateway/src/index.ts:200-204`），溢出 → `gateway/uplink-overflow`

### 0.4 `$events` 逻辑流（审批 / 提问往返）

常量（`api/gateway/src/stream-protocol.ts:10-19`）：`REMOTE_EVENT_STREAM_ENDPOINT = '$events'`（`:10`）· `REMOTE_EVENT_RESULT_ENDPOINT = '$events/result'`（`:13`）· `REMOTE_EVENT_STREAM_PAYLOAD = { args: {} }`（`:16`）· `REMOTE_EVENT_STREAM_READY = { type: 'ready' }`（`:19`）。

**下行**（端点 `$events`，走 mux；帧值 = `RemoteEventDownlinkFrame`，`stream-protocol.ts:67-71`）：

```jsonc
// 首帧，必须最先
{ "type": "ready", "clientId": "<uuid>", "host": { "home": "<主机 home 绝对路径>" } }
{ "type": "emit",     "event": "api-session/status", "args": [ "<sessionId>", true ] }
{ "type": "waterfall", "event": "approval/request", "eventId": "<uuid>", "agentId": "<agentId>", "request": { ... } }
{ "type": "cancel",   "eventId": "<uuid>" }
```

- 客户端对 `ready` 强制**精确三键** `{type, clientId, host}` 且 `host` 精确单键 `{home}`：`api/gateway/src/client/remote-events.ts:269-279`
- `waterfall.request` 强制**不含** `agent` / `signal`（由 `projectRemoteEventRequest` 剥离，`stream-protocol.ts:146-173`；客户端再校验 `remote-events.ts:302-303`）
- `emit.args` 是数组，按 `ctx.emit(name, ...args)` 展开

**上行应答**：HTTP POST `/api/$events/result`

```json
{ "type": "client-request", "rpcId": "<uuid>", "method": "$events/result",
  "payload": { "args": {
      "clientId": "<ready 帧的 clientId>",
      "eventId":  "<waterfall 帧的 eventId>",
      "outcome":  { "kind": "result", "value": <业务返回值> }
  } } }
```

- `outcome` 三态，精确键（`stream-protocol.ts:88-95`、解析 `:102-138`）：
  - `{ "kind": "next" }` — 交下一个 waterfall 监听者
  - `{ "kind": "result" }` 或 `{ "kind": "result", "value": <JSON> }`
  - `{ "kind": "rejected", "error": { "name": "<非空 string>", "message": "<string>", "code"?: "<string>", "details"?: <JSON> } }`
    （`RemoteEventRejection`，`stream-protocol.ts:80-85`；解析 `:349-365`）
- 客户端发送点：`api/gateway/src/client/remote-events.ts:211-223`
- 响应 `{ ok: true, value: undefined }`（`api/gateway/src/index.ts:426`）—— 即 `value` 缺席

**被转发的 Host 事件白名单**（`api/remotes/src/remote-events.ts:20-48`）：

```
mode=emit:     agent-preset/selected, api-session/activity, api-session/added, api-session/error,
               api-session/removed, api-session/status, commands/change,
               deepseek-account/session-expired, deepseek-account/model-sign-in-required,
               credentials/record-updated, credentials/reference-updated, goal/activation-changed,
               cordis/request-run, cordis/request-run-resolved, cordis/dynamic-package,
               cordis/dynamic-retract, cordis/inspect-query, cordis/inspect-query-resolved,
               llm/adapters-updated, permission-presets/catalog-changed, plugin-manager/changed,
               plugin-manager/install-log, plugin-manager/install-state, settings/document-updated,
               schedule/changed
mode=waterfall: approval/request, user-questions/request
```

### 0.5 HTTP 状态码 ↔ code

`code` **只**在 `result.error.code` 里，HTTP 状态码与业务失败**无映射关系**。业务失败一律 HTTP 200。

`200` 正常分发（`rpc-host.ts:295-302`）· `400` body 非 JSON（`:243-245`）· `401` 鉴权失败（`:105-106`、`:182-186`）· `403` Host/Origin 不可信（`:105`）· `404` 非 POST 或端点无人认领（`:231-232`、`:144-145`）· `413` 体超 300 MiB（`client/connection/src/http-bridge.ts:18`、`:63-70`）· `415` content-type 非 `application/json`（`:235-238`）· `500` handler 抛非 `RemoteError`（正常业务路径不发生，`:260-265`）。

- `method` 与路径端点不一致 → HTTP 200 + `gateway/bad-request`，`details: { issues: [] }`（`rpc-host.ts:252-258`）
- envelope 不合法 → HTTP 200 + `gateway/bad-request`，`details: { issues: <zod issues[]> }`（`rpc-host.ts:270-278`）
- 非 JSON 客户端侧：HTTP != 2xx 直接抛 `transport failure ... HTTP <status>`，读不到 body（`client/rpc.ts:58-60`）
- mux `error` 帧没有 HTTP 概念；`stream-client.ts:130-132` 直接 `throw new RemoteError(code, message, details)`

---

## 1. 会话 CRUD

### 1.1 `session.list` — RPC

`POST /api/session/list` · `api/session-controller/src/index.ts:251-254`

请求 `args`（`types.ts:264-266`）：`{ cursor?: string }`（实现忽略它，参数名写作 `_request`，`index.ts:252`）→ `{ "args": {} }`。
响应 `value`（`types.ts:268-271`）：`{ items: SessionSummary[] }`，`items` 必填。

`SessionSummary`（`types.ts:176-188`）：

`agentAvailable: boolean`(必, 是否持有活 Agent) · `sessionId: string`(必) · `updatedAt: number`(必, epoch ms, `max(createdAt, lastPromptAt)`，`list.ts:327-329`) · `running: boolean`(必) · `blank: boolean`(必, 折叠前缀内无 turn) · `parentSessionId?: string` · `origin?: 'subagent'` · `cwd?: string` · `projections?: SessionProjectionHints`

`SessionProjectionHints`（`types.ts:58-71`）：`kind: 'cached' | 'sequenced'`(必) · `asOfSeq: number`(必) · `values: SessionProjectionValues`(必，见 §7.1)

### 1.2 `session.create` — RPC

`POST /api/session/create` · `index.ts:272-275` → `commands.ts:105-144`

请求 `args`（`types.ts:284-290`）：`workspaceId?: string`（与 `cwd` **互斥**，同传报 `gateway/bad-request`，`commands.ts:106-108`）· `cwd?: string` · `sessionId?: string`（给了 = 幂等认领）· `agentPreset?: string`。四项全可选。
`{ "args": { "cwd": "<abs-path>/proj" } }`

响应 `value`（`types.ts:292-296`）：`sessionId: string`(必) · `agentPreset?: string`

### 1.3 `session.rename` — RPC

`POST /api/session/rename` · `index.ts:402-405` → `commands.ts:193-212`

请求 `args`（`types.ts:308-312`）：`sessionId: string`(必) · `title: string`(必，规范化后为空 → `session/title-invalid`)
响应 `value`（`types.ts:314-318`）：`title: string`(必，已规范化) · `seq: number`(必，提交它的持久事件 seq)

### 1.4 `session.fork` — RPC

`POST /api/session/fork` · `index.ts:414-417` → `commands.ts:221-304`

请求 `args`（`types.ts:320-325`）：`sessionId: string`(必) · `atSeq?: number`（省略 = 最后一个已完成 turn 的前缀，`commands.ts:75-85`；非负安全整数否则 `gateway/bad-request`）
响应 `value`（`types.ts:327-330`）：`{ sessionId: string }`

### 1.5 `session.cancel` — RPC

`POST /api/session/cancel` · `index.ts:456-459` → `commands.ts`（`cancel`）

请求 `args`（`types.ts:372-375`）：`{ sessionId: string }`，`sessionId` 必填。
响应 `value`（`types.ts:377-380`）：`{ accepted: true }` — `accepted` 是字面量 `true`，必填。

### 1.6 `SessionAddress`（`page` / `follow` 共用）

`types.ts:407-415`：

```ts
type SessionAddress =
  | { kind: 'session';  sessionId: SessionId }
  | { kind: 'subagent'; parentSessionId: SessionId; childSessionId: SessionId;
      mode: 'one-shot' | 'continuable' | 'unknown' }
```

- `kind:'session'` 指向 `header.origin === 'subagent'` 的子会话 → `session/agent-busy`，`details.reason='use subagent delivery for this child session'`（`history.ts:347-353`）
- `kind:'subagent'` 必须满足 `header.origin==='subagent' && header.parentSession===parentSessionId`（`history.ts:355-359`），否则 `subagent/unauthorized`
- 投影 `values.subagent === null` → `subagent/catalog-diagnostic` `reason:'corrupt'`；缺投影或 `seq < inheritedEventCount` → `reason:'unsupported'`（`history.ts:360-374`）
- `address.mode !== 'unknown'` 且与 `identity.mode` 不等 → `subagent/unauthorized`（`history.ts:375-379`）

### 1.7 `SessionHeader`（`SessionWireHeader`，`follow` 首帧携带）

`types.ts:431-443`，由 `wireHeader(header) = { ...header }` 直接拷贝（`history.ts:429-432`）；源定义 `core/session/src/types.ts:94-139`：

`version: 4`(必，`SESSION_FORMAT_VERSION = 4`，`core/session/src/types.ts:89`) · `id: string`(必) · `createdAt: number`(必, epoch ms) · `cwd?: string`（缺 `cwd` 的会话一律 not-found，`history.ts:254-257`）· `parentSession?: string` · `isSeeded: boolean`(必，是否含 fork 继承前缀) · `origin?: 'subagent'` · `delegationDepth?: number`（顶层会话缺席 = 0）· `agentPreset?: string` · `title?: string`

1.8 错误码（session 域）见 §11.2 汇总表。

---

## 2. 消息发送 `session.prompt` + `user/message` 事件

### 2.1 `session.prompt` — RPC

`POST /api/session/prompt` · `index.ts:425-429` → `commands.ts:311-377`

请求 `args`（`types.ts:332-341`）：`requestId: string`(必，客户端自铸幂等键，brand `types.ts:398`) · `sessionId: string`(必) · `mode: 'queue' | 'steer'`(必) · `content: PromptContentPart[]`(必，至少一段非空白 text 或一个附件) · `clientTimeZone?: string`（必须 `UTC` 或合法 IANA `Area/Location`，否则 `session/invalid-time-zone`）

`PromptContentPart`（`types.ts:89-97`）：`{ type:'text', text: string }` · `{ type:'image', mediaType: string, data: string /* base64 */, name?: string }` · `{ type:'file', receiptId: string }`（`receiptId` 来自同会话先前的 `fileUploads.upload`）

```json
{ "args": { "requestId": "r-1", "sessionId": "session-…", "mode": "queue",
            "content": [{ "type": "text", "text": "hello" }], "clientTimeZone": "Asia/Shanghai" } }
```

响应 `value`（`types.ts:343-346`）：`{ accepted: true }` — `accepted` 字面量 `true`，必填。
失败：空内容 / 非法时区 → `gateway/bad-request` / `session/invalid-time-zone`；模型不支持图片 → `session/attachment-invalid` `reason:'MODEL_DOES_NOT_SUPPORT_IMAGES'`；入队失败 → `session/agent-busy`（`commands.ts:312-372`）。

### 2.2 `user/message` 事件

`core/session/src/types.ts:317` — `'user/message': UserMessage`。

`UserMessage`（`llm/llm/src/message.ts:162-164` + 共享 `MessageBase` `:139-148`，四字段全必填）：`id: string`（`MessageId`）· `content: ContentBlock[]` · `source: MessageSource` · `role: 'user'`

内容块 `ContentBlock`（`llm/llm/src/types.ts:137-150`）七种：`text { text }`（`:62`）· `reasoning { text }`（`:68`）· `image { attachment: ImageAttachmentRef; offloaded?: true }`（`:79`）· `file { attachment: FileAttachmentRef }`（`:98`）· `tool-call { id; name; arguments }`（`:105`，`arguments` 是模型原样产出的未解析 JSON 串）· `tool-addition { toolName }`（`:115`，必须同时存在于 `developer/message.headerSeq` 指向的 header）· `tool-removal { toolName }`（`:127`）。除 `type` 外全部必填。

`ImageAttachmentRef`（`attachment/attachment/src/types.ts:11-32`）：`attachmentId`(必), `mediaType`(必), `bytes`(必), `width`(必), `height`(必), `name?`, `originalDimensions?: { width, height }`。

由 RPC 提示产生的 `source`（`api/session-controller/src/types.ts:400-405`）：

```ts
'user-rpc': { kind: 'user'; rpcId: SessionRequestId; clientTimeZone?: string }
```

其它 `MessageSourceMap` 成员（`llm/llm/src/message.ts:110-115`）：`user` = `{ kind: 'user' }`；`model` = `{ kind:'model', provider, model, replayState? }`；`tool` = `{ kind:'tool', callId }`；`system-prompt` = `{ kind:'system-prompt' }`。

事件 envelope 见 §3.3；`user/message` 是 surface 事件，`surfaceOp` **必填**（`core/session/src/types.ts:447-486`）。

---

## 3. 事件流线协议（`session.follow`）— 第 1 优先级

### 3.1 端点

**STREAM**，mux WS。`endpoint: 'session/follow'`，`payload: { args: <SessionFollowRequest> }`。
`api/session-controller/src/index.ts:479-482`；Host 实现 `history.ts:120-241`；客户端适配 `client/transport.ts:172-220`。

### 3.2 请求 `args`（`SessionFollowRequest`）

`types.ts:486-491`：

`address: SessionAddress`(必) · `assistantStream?: true`（**只有字面量 `true` 生效**；不带则整条 assistant 流不下发）· `maxMessages?: number`（正安全整数，默认 `50`，`history.ts:38`）· `turnWindow?: { minMessages: number; minTurns: number }`（两者正整数且 `minMessages ≤ maxMessages`，`history.ts:320-335`）

```json
{ "args": { "address": { "kind": "session", "sessionId": "session-…" },
            "assistantStream": true, "maxMessages": 50,
            "turnWindow": { "minMessages": 20, "minTurns": 2 } } }
```

> 客户端契约：只要请求带了 `assistantStream: true`，首帧 `assistantStream` **必返**，否则视为协议故障（`client/transport.ts:186-192`）。

### 3.3 下行帧 JSON envelope

mux 层：`{ "type": "item", "streamId": "<id>", "value": <SessionFollowFrame> }`。`value` 是 `SessionFollowFrame` 三选一（`types.ts:551-563`）。

#### 帧 A — `type: 'snapshot'`（首帧，恰好一次）

`type: 'snapshot'`(必, `types.ts:554`) · `header: SessionWireHeader`(必, `:555`，见 §1.7) · `cursor: number`(必, `:556`，已提交的最后 seq，空日志为 `-1`) · `records: SessionHistoryRecord[]`(必, `:557`，见 §3.4) · `hasMore: boolean`(必, `:558`) · `projections: SessionProjectionBaseline`(必, `:559`，见 §7) · `assistantStream?: SessionAssistantStreamBaseline`（仅当请求 `assistantStream: true`，`:560`）

```json
{ "type": "snapshot",
  "header": { "version": 4, "id": "session-…", "createdAt": 1690000000000, "cwd": "/p", "isSeeded": false },
  "cursor": 812,
  "records": [ { "type": "event", "event": { "type": "turn/start", "seq": 811, "time": 1690000000123, "data": { "turn": 12 } } } ],
  "hasMore": true,
  "projections": { "asOfSeq": 812, "values": { "modelSelection": { "lastUsed": null, "next": null } } },
  "assistantStream": { "revision": 41, "activeAttempt": {
      "attemptId": "att-…", "startedAfterSeq": 811, "turn": 12, "step": 3, "nextIndex": 57,
      "stream": [ { "type": "text-chunks", "time0": 1690000000200, "index": 0, "dt": [12, 9], "texts": ["Hel", "lo"] } ] } } }
```

`SessionAssistantStreamBaseline`（`types.ts:506-510`）：`revision: number`(必) · `activeAttempt?: SessionAssistantStreamAttempt`
`SessionAssistantStreamAttempt`（`types.ts:493-504`，全必填）：`attemptId: string` · `startedAfterSeq: number` · `turn: number` · `step: number` · `nextIndex: number` · `stream: JsonValue[]`

#### 帧 B — 单条 durable 事件

`SessionEventEntry`（`types.ts:425-429`）：`type: 'event'`(必) · `event: SessionWireEvent`(必)

`SessionWireEvent`（`types.ts:453-468`，客户端逐字段校验 `client/session-wire-event.ts:14-46`）：

`type: string`(必，非空) · `seq: number`(必，非负安全整数，非 `-0`) · `time: number`(必，安全整数 epoch ms) · `data: JsonValue`(必，不得为 `undefined`，owner 自定义) · `ignorable?: true`（出现时必须严格等于 `true`）· `surfaceOp?: 'append' | { op:'replace', startSeq: number, endSeq: number }` · `sourceEventSeqs?: JsonValue`（实为 `number[]`）

客户端只接受这 7 个键，出现第 8 个键即抛错（`session-wire-event.ts:20-33`）。

**surface 事件白名单**（`core/session/src/types.ts:447-453`）：`system/message`、`developer/message`、`user/message`、`assistant/message`、`tool/result` — 这 5 种 `surfaceOp` **必填**，其余事件 `surfaceOp`/`sourceEventSeqs` **禁止出现**（`:520-523`）。`replace` 的 `startSeq`/`endSeq` 必须指向更早的 seq（`core/session/src/surface.ts:410-418`）。

**seq 连续性**：Host 保证 `cursor+1, cursor+2, …` 严格 +1；跳号会抛 `gateway/internal`（`history.ts:226-231`）。`seq < expected` 的重复事件被丢弃。

#### 帧 C — `type: 'assistant-stream'`

`type: 'assistant-stream'`(必) · `frame: SessionAssistantStreamFrame`(必)

`SessionAssistantStreamFrame`（`types.ts:512-543`）三选一（除标 `?` 者外全部必填）：

- `start` — `attemptId: string` · `revision: number` · `startedAfterSeq: number` · `turn: number` · `step: number`（`:514-521`）
- `chunk` — `attemptId: string` · `revision: number` · `index: number`（attempt 内从 0 密集递增）· `time: number` · `chunk: JsonValue`（`:522-529`）
- `end` — `attemptId: string` · `revision: number` · `index: number`（本 attempt 的 chunk 帧总数）· `outcome`（`:530-543`）

`outcome` 二选一：`{ kind: 'committed'; eventType: 'assistant/message' | 'assistant/attempt'; seq: number }` 或 `{ kind: 'abandoned' }`。

**`revision` 规则（硬约束）**：首帧 `assistantStream.revision` 记为 `R0`，此后每个 `assistant-stream` 帧的 `frame.revision` 必须严格 `R0+1, R0+2, …`。跳号 → `RemoteStreamCarrierError`（`client/transport.ts:206-215`）。`start` 帧的 `revision === 1` 且当前 revision ≠ 0 表示 Agent 换代，revision 归零重排（`session-controller/src/assistant-stream.ts:39-42`）。

`chunk.chunk` 的实际取值域是 `StreamChunk`（`llm/llm/src/types.ts:452-464`）：

```ts
{ type: 'block-start';     index: number; blockType: ContentBlockType }
{ type: 'text-delta';      index: number; text: string }
{ type: 'reasoning-delta'; index: number; text: string }
{ type: 'tool-call-delta'; index: number; id: ToolCallId; name?: string; argumentsDelta: string }
{ type: 'block-end';       index: number; block: ContentBlock }
{ type: 'usage';           usage: TokenUsage }
{ type: 'finish';          reason: FinishReason; replayState?: ReplayEnvelope }
```

`FinishReason`（`llm/llm/src/types.ts:156-165`）：`{kind:'stop'} | {kind:'tool-calls'} | {kind:'max-tokens'} | {kind:'aborted', failure} | {kind:'error', failure}`。

> `assistant-stream` 帧**无 seq**，不参与游标代数；它必须排在 gap 修复之后（`api/gateway/src/client/journal-stream.ts:22`、`:86-88`）。

### 3.4 `SessionHistoryRecord`

`types.ts:450-451` — `type SessionHistoryRecord = SessionEventEntry`，即 `{ type: 'event', event: SessionWireEvent }`。没有别的形态。

### 3.5 `session.page`（历史分页，RPC）

`POST /api/session/page` · `index.ts:467-470` → `history.ts:77-112`

请求 `args`（`SessionPageRequest`，`types.ts:470-484`）：`address: SessionAddress`(必) · `throughSeq: number`(必，≥ -1，从 follow 首帧 `cursor` 取；超过当前游标 → `gateway/bad-request`) · `beforeSeq?: number`(≥ 0) · `maxMessages?: number`（默认 50）· `turnWindow?: { minMessages, minTurns }`

响应 `value`（`types.ts:545-549`）：`{ records: SessionHistoryRecord[], hasMore: boolean }`，两字段均必填。分页算法 `history.ts:392-427`：只数 `user/message` 与 `assistant/message` 的 append 事件。

### 3.6 完整 Session 事件类型全集

`core/session/src/known-event-types.ts:22-83`（61 个）：

```
agent-preset/selected, agent/inbox/spliced, agent/unattended, approval/asked, approval/decided,
approval/policy, assistant/attempt, assistant/message, command/done, command/run,
compaction/end, compaction/prune, compaction/start, compaction/summary, deliverables/presented,
developer/message, feedback/message-delete, feedback/message-put, feedback/record, goal/change,
hook/invoked, hook/result, image/offload, llm/retry, llm/retry-started, model/selection,
permission/preset, plan/mode, request/context, request/header, sandbox/mode, schedule/change,
session-log-deepseek/delivery-accepted, session/end-seed, session/title, session/title-llm-request,
step/end, step/start, subagent/catalog, subagent/descriptor, subagent/model-selection-policy,
system/message, team/member, team/message/delivered, team/message/queued, team/task, todo/write,
tool-workflow/agent-end, tool-workflow/agent-start, tool-workflow/run-end, tool-workflow/run-start,
tool/call, tool/ptc-dispatch, tool/ptc-dispatch-start, tool/result, turn/end, turn/start,
user/message, web/deepseek-search-llm-request, workspace/changes
```

遇到不在此集合内且**没有** `ignorable: true` 的事件，持久化读取路径会拒绝重建会话（`known-event-types.ts:8-21`）。

核心事件 `data` 形状（`core/session/src/types.ts:289-436`；除标 `?` 者外全部必填）：

`turn/start` `{ turn }` · `turn/end` `{ turn, reason: TurnEndReason }` · `step/start` `{ turn, step }` · `step/end` `{ turn, step }` · `user/message` = `UserMessage`（见 §2.2）· `developer/message` `{ turn, step, message: DeveloperMessage, headerSeq? }` · `system/message` `{ turn, step, message: SystemMessage }` · `assistant/message` `{ turn, step, message: AssistantMessage, stream: AssistantStreamRecord[], usage?: TokenUsage, interrupted?: true }` · `assistant/attempt` `{ turn, step, stream: AssistantStreamRecord[] }` · `tool/call` `{ turn, step, callId, name, arguments }` · `tool/result` `{ turn, step, message: ToolResultMessage, error?: { name, code, reason? }, meta?: JsonValue }` · `request/header` `{ header: EpochHeader, reason: 'initial'|'resume'|'change'|'series', startsSeries?: true }` · `request/context` `{ provider, model, contextWindow?, systemPromptUpdate? }` · `session/end-seed` `{ inherited?: true }` · `model/selection` = `ModelSelection`（`api/session-controller/src/types.ts:34-42`）。

`TurnEndReason`（`core/session/src/types.ts:209-240`）：`{kind:'completed'} | {kind:'aborted', reason} | {kind:'blocked'} | {kind:'error', error} | {kind:'max-tokens'} | {kind:'interrupted'} | {kind:'forked'}`。

`AssistantStreamRecord`（`llm/llm/src/assistant-stream.ts:20-45`，`assistant/*` 内嵌的紧凑流）：`{ type:'text-chunks'|'reasoning-chunks', time0, index, dt: number[], texts: string[] }` / `{ type:'tool-call-chunks', time0, index, dt, id, name?, args: string[] }` / `{ type:'chunk', time, chunk: StreamChunk }`。

### 3.7 `session.control` — STREAM

`endpoint: 'session/follow'` 之外的第二条流：`endpoint: 'session/control'`，`payload: { args: {} }`（该方法只有 `signal` 参数，`index.ts:519-522`）。

`SessionControlFrame`（`types.ts:578-581`）**只有两个成员**：
`{ type: 'baseline'; value: { projections: Record<sessionId, SessionProjectionBaseline> } }`（`:580`、`:565-568`）· `{ type: 'projection'; sessionId: string; key: string; value: JsonValue; seq: number }`（`:571-576`、`:581`）

首帧恰好一个 `baseline`，其后全是增量 `projection`（`control.ts:42-53`）。这是 Host 全局投影变化流，键为 §7.1 的投影 key。

---

## 4. 审批（`approval/request`）

### 4.1 触发方式

**EVENT waterfall**，`event: 'approval/request'`，走 §0.4。
声明：`interaction/user-approval/src/types.ts:78-92`；白名单：`api/remotes/src/remote-events.ts:22`。

`waterfall.request` 的 wire 内容 = `ApprovalRequestEvent` 去掉 `agent` 与 `signal`（`stream-protocol.ts:146-173`）：
`toolName: string`(必, `user-approval/src/types.ts:67`) · `callId?: string`(`:69`) · `reason?: string`(`:71`) · `displayReason?: { en: string; [locale: string]: string }`(`:73`，仅本地化展示，永不持久化)

```json
{ "type": "waterfall", "event": "approval/request", "eventId": "e-…", "agentId": "agent-…",
  "request": { "toolName": "write_file", "callId": "call-1", "reason": "writes outside workspace" } }
```

### 4.2 action 选项（应答取值域）

`ApprovalOutcome`（`interaction/user-approval/src/types.ts:32`）—— **四个字面量，无对象结构**：`'allowed-once'`（一次性放行）· `'rejected'`（显式拒绝）· `'cancelled'`（请求被撤销）· `'unavailable'`（无应答者，调用方 fail-closed）。

交互式 UI 只应返回前两个；官方客户端类型 `ApprovalDecision = 'allowed-once' | 'rejected'`（`client/ui-approval/src/client/contract/slots.ts:66`）。

### 4.3 应答

**无独立 RPC 路由。** 走 `/api/$events/result`：

```json
{ "type": "client-request", "rpcId": "<uuid>", "method": "$events/result",
  "payload": { "args": { "clientId": "<ready.clientId>", "eventId": "<eventId>",
                         "outcome": { "kind": "result", "value": "allowed-once" } } } }
```

`outcome.value` 是裸字符串（不是 `{ outcome: … }` 对象）。

取消：Host 下发 `{ type: 'cancel', eventId }` 后不应再回结果（`api/gateway/src/client/remote-events.ts:148-151`）。

### 4.4 审计事件

`interaction/user-approval/src/types.ts:34-59`（log-only，无 `surfaceOp`）：

```ts
'approval/asked':   { id: string; toolName: string; callId?: string; reason?: string }
'approval/decided': { id: string; outcome: ApprovalOutcome }
```

`approval/policy` 事件存在于类型集合（`known-event-types.ts:28`）但本包未声明其 `data`。

---

## 5. 提问（`user-questions/request`）— 第 2 优先级

### 5.1 触发方式

**EVENT waterfall**，`event: 'user-questions/request'`，走 §0.4。
声明：`interaction/user-questions/src/types.ts:79-93`；白名单：`api/remotes/src/remote-events.ts:47`。

`waterfall.request` wire 内容 = `AskUserQuestionRequestEvent` 去掉 `agent` / `signal`：唯一字段 `questions: AskUserQuestionItem[]`(必，`user-questions/src/types.ts:72`)。

`AskUserQuestionItem`（`user-questions/src/types.ts:36-51`）：
`id: string`(必，稳定 id，原样回显在 answer 中) · `question: string`(必) · `detail?: string`（随问题展示的补充说明，不进 option label）· `header?: string`（短标题 / 分组标签）· `options?: { label: string; description?: string }[]`（省略 = 自由文本）· `multiSelect?: boolean`（**缺省 = 单选**）· `intent?: AskUserQuestionIntent`（省略 = 通用选项流）

```json
{ "type": "waterfall", "event": "user-questions/request", "eventId": "q-…", "agentId": "agent-…",
  "request": { "questions": [
    { "id": "q1", "header": "Deploy", "question": "Which environments?",
      "options": [{ "label": "staging", "description": "recommended" }, { "label": "prod" }],
      "multiSelect": true },
    { "id": "q2", "question": "Anything else?" }
  ] } }
```

### 5.2 能力矩阵（本版本实际语义）

- **多问题批量** — `questions.length > 1`，一次往返必须答完所有 id（结构本身；`AskUserQuestionAnswer.answers` 是数组，`:64-67`）
- **单选** — `options` 存在且 `multiSelect` 缺席/`false`（`:48`）
- **多选** — `options` 存在且 `multiSelect === true`（`:48`）
- **自由文本（custom）** — answer item 携带 `custom?: string`；**可与 `selected` 并存**（多选场景即 custom + 已选项）（`:54-61`）
- **纯自由文本** — `options` 缺席 ⇒ `selected: []` + `custom`（`interaction/tool-ask-user/src/index.ts:81-98` 的 tool schema 中 `options` 非必填）
- **可跳过（skip）** — **协议层无 skip 字段。** 官方 UI 的「跳过」是把当前项从 `answers` 里省略或留空数组；被跳过的项在 `ask_user_question` 的 tool result 里就没有该 id。**skip 的 UI 语义由 App 自己实现**
- **plan-review** — `intent.kind === 'plan-review'`（见 §5.4）

模型侧工具 schema（`interaction/tool-ask-user/src/index.ts:32-70`）确认：`questions[].id`/`question` 必填；`header`/`options`/`multi_select`（映射为 `multiSelect`）可选；answer schema 强制 `answers[].id` 与 `answers[].selected`，`custom` 可选。

### 5.3 应答请求体

**无独立 RPC 路由。** 走 `/api/$events/result`：

```json
{ "type": "client-request", "rpcId": "<uuid>", "method": "$events/result",
  "payload": { "args": { "clientId": "<ready.clientId>", "eventId": "<eventId>",
    "outcome": { "kind": "result", "value": { "answers": [
      { "id": "q1", "selected": ["staging"], "custom": "先灰度 5%" },
      { "id": "q2", "selected": [], "custom": "没有了" }
    ] } } } } }
```

`AskUserQuestionAnswerItem`（`user-questions/src/types.ts:54-61`）：`id: string`(必) · `selected: string[]`(必，可为空数组) · `custom?: string`
外层 `value` = `{ answers: AskUserQuestionAnswerItem[] }`（`:64-67`），`answers` 必填。

拒答 / 放弃：`{ "kind": "rejected", "error": { "name": "UserQuestionError", "message": "...", "code": "ASK_CANCELLED" } }`；`code` 约定值 `'ASK_ABORTED' | 'ASK_CANCELLED'`（`client/ui-user-questions/src/client/contract/slots.ts:106`）。`ASK_CANCELLED` 会被 plan-mode 专门识别（`plan/plan-mode/src/index.ts:325-334`）。

### 5.4 `plan-review` 特化形态

`AskUserQuestionIntent`（`user-questions/src/types.ts:22-33`）= `{ kind: 'plan-review'; approve: string; callId?: string }`
`kind`(必，判别字面量) · `approve: string`(必，**批准用的 option label**；其它任何 option = 拒绝。按名而非按位置，UI 不得从顺序推断) · `callId?: string`（含被审计划的 tool 调用 id）

与普通 question 的字段差异：**唯一差异就是多一个 `intent` 对象**。`id`/`question`/`detail`/`header`/`options`/`multiSelect` 全部照常。官方 `ask()` 校验：`intent.approve` 必须在同题 options 里命名到选项，否则 `ask()` 直接拒绝（`user-questions/src/types.ts:28-30`）。

官方 `plan-mode` 产出的实例（`plan/plan-mode/src/index.ts:306-325`）：

```json
{ "questions": [{
    "id": "plan-review",
    "header": "Plan review",
    "question": "Approve this plan and leave plan mode?",
    "detail": "# 计划 markdown…",
    "options": [
      { "label": "Approve",   "description": "Leave plan mode; the plan is carried out from the next step." },
      { "label": "Keep planning", "description": "Stay in plan mode; feedback goes back to the model." }
    ],
    "intent": { "kind": "plan-review", "approve": "Approve", "callId": "call-…" }
} ] }
```

客户端识别条件（`client/ui-user-questions/src/client/contract/slots.ts:81-101`，`planReviewOf`）—— 全部满足才渲染为审批卡：

1. `questions.length === 1`
2. `intent.kind === 'plan-review'`
3. `question.detail !== undefined`（计划正文在 `detail`）
4. `multiSelect !== true`
5. `options.length ≤ 2`
6. 存在 `option.label === intent.approve`

不满足 → 退回通用问题流（协议与 answer 编码完全相同，`user-questions/src/types.ts:15-21`）。客户端收窄后的 `PlanReview`：`{ id, question, plan(=detail), callId?, approve, decline? }`（`slots.ts:54-67`）。

---

## 6. 模型目录与选择

### 6.1 `session.modelCatalog` — RPC

`POST /api/session/modelCatalog` · `index.ts:309-312` → `catalog.ts:20-72`
**无请求参数** → `args: {}`。App 零硬编码，目录完全靠此路由。

响应 `value` = `ModelCatalog`（`types.ts:157-164`，四字段全必填）：
`default: ModelSelection` · `routableProviders: string[]`（至少有一个可用模型的 provider id）· `groups: ModelProviderGroup[]`（空模型的 provider 已被过滤掉，`catalog.ts:64-65`）· `failures: ModelCatalogFailure[]`（取目录失败的 provider 被隔离，不影响其他）

`ModelSelection`（`types.ts:99-104`）：`provider: string`(必) · `model: string`(必) · `reasoningEffort?: string`
`ModelProviderGroup`（`types.ts:143-148`）：`id: string`(必) · `name: string`(必) · `models: ModelCatalogModel[]`(必)
`ModelCatalogModel`（`types.ts:135-141`）：`id: string`(必) · `name: string`(必) · `description?: string` · `reasoning?: ModelReasoning`
`ModelReasoning`（`types.ts:129-133`）：`efforts: ModelReasoningEffort[]`(必，adapter 偏好展示顺序) · `defaultEffort?: string`（缺席 = 保留 provider 自己的默认）
`ModelReasoningEffort`（`types.ts:122-127`）：`id: string`(必) · `name: string`(必) · `description?: string`
`ModelCatalogFailure`（`types.ts:150-155`）：`id: string`(必) · `name: string`(必) · `message: string`(必)

```json
{ "default": { "provider": "deepseek-official", "model": "deepseek-v4" },
  "routableProviders": ["deepseek-official"],
  "groups": [{ "id": "deepseek-official", "name": "DeepSeek",
    "models": [{ "id": "deepseek-v4", "name": "DeepSeek V4",
      "reasoning": { "efforts": [{ "id": "low", "name": "Low" }, { "id": "high", "name": "High" }],
                     "defaultEffort": "medium" } }] }],
  "failures": [{ "id": "openai", "name": "OpenAI", "message": "no API key" }] }
```

模型目录变更信号：EVENT `llm/adapters-updated`（`llm/llm/src/types.ts:12-25`；白名单 `api/remotes/src/remote-events.ts:40`）。

### 6.2 `session.selectModel` — RPC

`POST /api/session/selectModel` · `index.ts:282-285` → `commands.ts:151-186`

请求 `args`（`SessionSelectModelRequest extends ModelSelection`，`types.ts:298-301`）：`sessionId: string`(必) · `provider: string`(必) · `model: string`(必) · `reasoningEffort?: string`
响应 `value`（`types.ts:303-306`）：`{ selected: ModelSelection }`，`selected` 必填且是**引擎归一化后**的（`commands.ts:163-176`）。

### 6.3 「跟随默认」怎么表达

**协议层没有 `followDefault` 标志。** 语义由两处表达：

1. **`modelSelection` 投影**（`api/session-controller/src/model-selection-projection.ts:58-68`）= `{ lastUsed: ModelSelection | null, next: ModelSelection | null }`（zod wire `:24-27`，两者都可 null）。`next` 的 view 是 `pending ?? lastUsed`（`:65`）：`next === null` 表示该会话还从未做过选择，**即跟随部署默认**。
2. **`ModelCatalog.default`** —— 部署级默认（`catalog.ts:22`、`:67`）。

即：App 要表达「跟随默认」时**不要调 `selectModel`**，改为在 UI 上把 `projections.values.modelSelection.next` 显示为 `ModelCatalog.default`。若用户显式点了「用默认」，把 `catalog.default` 的三个字段原样发给 `selectModel` 即可（`reasoningEffort` 缺席表示用该 route 的 `defaultEffort`）。

### 6.4 其它模型面（长尾）

- `llm.listProviders` → `LlmProviderInfo[]`（`llm/llm/src/types.ts:223-228`：`{ id, name }`），`llm/llm/src/index.ts:477-480`
- `llm.listConfigurableProviders` → `llm/llm/src/index.ts:549-552`
- `llm.discoverModels` → `llm/llm/src/index.ts:637`
- `session.initializeDefaultModel()` → `void`，`index.ts:291-303`（无参，`args: {}`）

---

## 7. 上下文

**关键事实：`contextPressure` / `contextBreakdown` / `tokenUsage` 都是「投影」，不是 Session 事件。** 全仓库无 `contextPressure` / `contextBreakdown` 事件类型（`known-event-types.ts:22-83` 里没有）。

### 7.1 投影 key 与 wire 结构

`SessionProjectionValues`（`types.ts:80-82`）= `Partial<SessionProjectionMap> & Record<string, JsonValue>`。已声明的 key（`SessionProjectionMap` 声明合并；全部为投影，**没有同名事件**）：

`tokenUsage` / `contextPressure` / `contextBreakdown`（`llm/token-meter/src/projection.ts:71`、`:73`、`:75`）· `modelSelection`（`api/session-controller/src/types.ts:30`）· `sessionListMetadata`（`:26`）· `imageLimits`（`:28`）· `subagentCatalog` / `subagentTiming` / `subagent`（`subagent/subagent/src/projection-types.ts:71`、`:73`、`:83`）· `inbox`（`core/agent/src/types.ts:65`）· `sessionStats`（`session/session-stats/src/types.ts:44`）· `turnOutline`（`session/session-turn-outline/src/types.ts:47`）· `todos`（`todo/tool-todo/src/types.ts:45`）· `agentPreset`（`preset/agent-preset-registry/src/types.ts:56`）· `plan`（`plan/plan-mode/src/types.ts:45`）· `turnBoundary`（`core/agent/src/types.ts:78-87`）· `title`（`session/session-title/src/index.ts:262-275`）· `agentTeam`（`experimental/agent-team/src/types.ts:123`，实验）。

**缺席语义**：`values` 里没有某个 key = 该 Session 在此 cut 上不具备该能力，**不是零值**（`types.ts:75-77`）。

`SessionProjectionBaseline`（`types.ts:73-78`）：`asOfSeq: number`(必) + `values: SessionProjectionValues`(必)。

### 7.2 `contextPressure` — 总量 / 已用 / 容量

`ContextPressureProjection`（`llm/token-meter/src/projection.ts:30-48`），wire zod = `usage-projection.ts:67-75`（三个字段全部 `.optional()`，`.strict()`）：

| 字段 | 类型 | 必填 | 语义 |
|---|---|---|---|
| `pressureTokens` | `number` | 否 | 最近一次请求的 prompt 侧占用 = `inputTokens + cacheReadTokens + cacheWriteTokens`（`usage-projection.ts:78-79`），**不含输出** |
| `projectedTokens` | `number` | 否 | 下一次请求的预估 prompt 成本 = `pressureTokens` + surface 增量（`usage-projection.ts:210-216`） |
| `contextWindow` | `number` | 否 | 最新记录的 route 容量（`projection.ts:47`） |

**三者刻意不是同一次请求的原子观测**：换模型时可能把新容量与旧 route 的压力配对。`pressureTokens` 与 `projectedTokens` 在 provider 报告 usage 前一律缺席（`projection.ts:33-45`）。UI 只应作文用参考，不得当计费或门禁依据。

### 7.3 `contextBreakdown` — system / tools / 对话三段分解

`ContextBreakdownProjection`（`llm/token-meter/src/projection.ts:59-66`），wire zod = `breakdown-projection.ts:24-28`，**三字段全必填、`.strict()`**：
`systemTokens: number`（surface 顺序中**最后一个非空存活 system prompt** 的启发式 token；无则 `0`）· `toolsTokens: number`（最新 `request/header` 的 tool schema 启发式 token；请求前为 `0`）· `messageTokens: number`（其余全部可见 surface 节点，含被取代的旧 system prompt）

三者用固定密度估算，**不会**与 provider 锚定的 `projectedTokens` 相加相等；只能当「构成分解」展示，不能当总量（`projection.ts:50-58`）。

### 7.4 读取路径

- `POST /api/session/projections`，`args: { sessionId }` → `{ asOfSeq, values }` 或 `null`（会话不存在）（`index.ts:490-512`；`types.ts:417-423`）
- follow 首帧 `snapshot.projections`（`types.ts:559`）
- control 流 `baseline.value.projections[sessionId]` / `projection` 帧（`types.ts:565-581`）
- 列表行 `SessionSummary.projections`（`kind` 决定 `asOfSeq` 能否与基线比较，`types.ts:58-71`）

---

## 8. 用量统计

**关键事实：无 `tokenUsage` 事件。** 它是投影 key（`llm/token-meter/src/usage-projection.ts:117-150`）。

### 8.1 `tokenUsage` 投影

wire = `TokenUsageProjection`（`llm/token-meter/src/projection.ts:13-18`），zod `usage-projection.ts:45-50`，**四字段全必填、`.strict()`**：
`uncachedInputTokens: number`（未命中缓存的输入，**仅此**）· `outputTokens: number`（输出；**reasoning tokens 已含在内，不重复累加**）· `cacheReadTokens: number`（缓存读命中）· `cacheWriteTokens: number`（缓存写）

计费输入 = 三者之和。来源是 `assistant/message` 的 `data.usage` 或其 `stream` 内最后一条 `usage` chunk（`usage-projection.ts:21-26`、`:81-86`）。

### 8.2 逐次 `TokenUsage`（在事件里，不在投影里）

`llm/llm/src/types.ts:175-189`，出现在 `assistant/message` 的 `data.usage`：
`inputTokens: number`(必) · `outputTokens: number`(必) · `totalTokens?: number` · `cacheReadTokens?: number` · `cacheWriteTokens?: number` · `reasoningTokens?: number`

### 8.3 「tok 每秒」与「轮次」

**协议里没有直接的 tok/s 字段。** 官方做法是从 `sessionStats` 投影自行相除：

`SessionStatsProjection`（`session/session-stats/src/types.ts:22-39`），zod `session/session-stats/src/projection.ts:72-81`，**八字段全必填、`.strict()`**：

`turns: number`（至少闭合过一个 step 的不同 turn 数，被拒/空 turn 不计）· `steps: number`（闭合的 `step/end` 数）· `llmMs: number`（`step/start` → `assistant/message` 累计墙钟）· `toolMs: number`（`tool/call` → `tool/result` 按 callId 配对累计）· `ttftMs: number`（首批 token 延迟累计）· `ttftSteps: number`（有首 token 的 step 数）· `decodeMs: number`（首 token → `assistant/message` 累计）· `decodeTokens: number`（同批 step 的 provider 输出 token 累计）。

**tok/s = `decodeTokens / (decodeMs / 1000)`**（`decodeMs > 0` 时）。轮次 = `turns`。

---

## 9. 子代理

### 9.1 目录读取（无独立路由）

**`subagent.catalog` 路由在 0.1.7-rc.2 不存在。** `SubagentRuntime` 只有两个 `@Remote`：`prompt`、`interruptByParent`（`subagent/subagent/src/index.ts:415`、`:482`）。目录以**投影 + 事件**形式存在。

`subagentCatalog` 投影 = `SubagentCatalogEntry[]`（`subagent/subagent/src/projection-types.ts:10-19`）：
`id: string`(必，子会话 id) · `createdAt: number`(必) · `mode: 'one-shot' | 'continuable' | 'unknown'`(必，判别联合) · `label: string`（`continuable` 必填；`one-shot`/`unknown` 可选）

- 「与父会话的关联」**不在这份数据里**——子条目本身没有 `parentSessionId`；父子关系由「该投影属于哪个 Session」隐含，读取时必须带上父 `sessionId`（`subagent/subagent/src/list-children.ts:31-54`）。
- 运行状态**不在** `subagentCatalog` 里。递归列表另有 `SubagentCatalogRow`（`subagent/subagent/src/control-types.ts:25-47`）追加 `activity: 'running' | 'inactive'`，但那是 Host 内部遍历产物，**不上 wire**。运行时状态要看 `api-session/status` EVENT（§0.4 白名单）或 `SessionSummary.running`。

来源事件 `subagent/catalog`（`subagent/subagent/src/catalog.ts:28-45`，父会话 log-only 事件）：
`{ version: 0|1; childId: string; childCreatedAt: number; mode: 'one-shot'|'continuable'|'unknown'; label?: string }`
zod 精确 schema：`catalog.ts:54-73`（`.strict()`，三变体；`continuable` 的 `label` 必填）。`version: 1` 才允许 `mode: 'unknown'`（`catalog.ts:34`）。当前写出常量 `SUBAGENT_CATALOG_VERSION = 0`（`catalog.ts:21`）。

`subagent` 投影（**子会话自己的**身份，`projection-types.ts:45-66`）= `{ mode: 'one-shot'; label?: string; seq: number }` | `{ mode: 'continuable'; label: string; seq: number }` | `null`（⟺ 无合法 descriptor）。
`subagentTiming` 投影（`projection-types.ts:22-37`）：`settledMs: number`(必) · `active?: { since, through }` · `lastTurnCompleted?: boolean`；zod `subagent/subagent/src/projection.ts:31-45`。

### 9.2 只读约束怎么表达

**协议层没有一个 `readOnly: true` 字段。** 它由以下三条事实的组合推导，App 必须照此实现：

1. **`mode` 就是只读判据。** `subagentCatalog` 条目 `mode === 'one-shot'` ⇒ 终态子代理，**只读**（`descriptor.ts:60-69`）。`mode === 'unknown'` ⇒ 读子会话历史后才能确定（`client/ui-subagent/src/client/index.ts:40`）。
2. **写路径在 Host 侧硬拒。** `subagents.prompt` 的请求 `mode` 字段是**必填字面量 `'continuable'`**（`subagent/subagent/src/control-types.ts:91`）；非 continuable 目标 → `subagent/not-resumable`（`control-types.ts:132`）。
3. **父不在线也只读。** `subagents.prompt` 找不到活的父 Agent → `subagent/parent-unavailable`（`subagent/subagent/src/index.ts:430-436`）。

官方客户端把这三条收窄为 UI 三态（`client/ui-subagent/src/client/SubagentReadOnlyComposer.tsx:7`）：`'one-shot'`（`subagent.address.mode === 'one-shot'`，`ui-subagent/src/client/index.ts:41`）· `'unknown'`（`mode === 'unknown'`，`:40`）· `'parent-unavailable'`（`parentAvailable === false` 且 `session.running !== true`，`:44-48`）。

### 9.3 `subagents.prompt` — RPC

`POST /api/subagents/prompt` · `subagent/subagent/src/index.ts:415-464`

请求 `args`（`SubagentPromptRequest`，`control-types.ts:85-102`）：`requestId: string`(必) · `parentSessionId: string`(必) · `childSessionId: string`(必) · `mode: 'continuable'`(必，字面量) · `delivery: 'queue' | 'steer'`(必) · `content: PromptContentPart[]`(必) · `clientTimeZone?: string`
响应 `value`（`control-types.ts:105-107`）：`{ messageId: string }`

### 9.4 `subagents.interruptByParent` — RPC

`POST /api/subagents/interruptByParent` · `subagent/subagent/src/index.ts:482-503`
请求 `args` 三个并列 wire 字段（不是嵌套对象）：`childSessionId: string`(必), `parentSessionId: string`(必), `mode: 'continuable'`(必)。
响应 `value`（`control-types.ts:110-112`）：`{ accepted: true }`。

### 9.5 subagent 错误码

见 §11.2 的 subagent 域 8 个码。

---

## 10. 任务：`job` 与 `todo`

### 10.1 `job` — 三个路由，`/api/job/*`

`api/job-controller/src/index.ts:59`（namespace `job`）。

**`job.list` — STREAM**（`index.ts:75-78`）
`args: { sessionId: string }`（`types.ts:15-17`）。
帧 `JobListFrame`（`types.ts:24-27`）：`{ type: 'rows', jobs: JobView[] }` — **整体替换**，开流首帧即全量 truth（`rows.ts:40-46`）。

**`job.follow` — STREAM**（`index.ts:90-96`）
`args`（`JobFollowRequest`，`types.ts:49-61`）：`sessionId?: string`（无归属 job 省略）· `jobId: string`(必) · `from?: number`（绝对字节偏移；省略 = 从最老保留字节）
帧 `JobFollowFrame`（`types.ts:72-90`）三选一：
`{ type: 'opened'; job: JobView; from: number }` · `{ type: 'output'; chunks: JobChunk[]; next: number; lossy?: true }` · `{ type: 'status'; job: JobView }`（终态，**之后流正常关闭**）

**`job.kill` — RPC**（`index.ts:109-127`）
`args`（`JobKillRequest`，`types.ts:30-34`）：`sessionId: string`(必), `jobId: string`(必)。
响应 `value`（`types.ts:37-39`）：`{ outcome: 'requested' | 'already-finished' }`。
错误：`job/not-found` `{ sessionId, jobId }`（`types.ts:44`）。

### 10.2 `JobView`（任务卡三态字段）

`jobs/jobs/src/view.ts:65-99`：
`id: string`(必，形如 `<kind>-N`) · `kind: string`(必，producer kind，开放字符串，当前 `bash`/`subagent`，`:32-35`) · `label: string`(必) · `owner?: string`（归属会话；缺席 = 无归属，人人可见）· `outputLimitBytes?: number` · `status: JobStatus`(必，见下) · `progress?: string`（结算时清空）· `detail?: string`（终局原因：退出码、被 kill 原因）· `startedAt: number`(必, epoch ms) · `finishedAt?: number`（活着时缺席）· `output: { total: number; earliest: number; spillPaths?: string[] }`(必，环形缓冲绝对坐标)

**`JobStatus`（五态，`view.ts:19`）**：`'running'` → 可选 `'stopping'` → 恰好一个终态 `'completed' | 'killed' | 'failed'`。所谓「三态」指终态三选一；完整生命周期是五态。

`JobChunk`（`view.ts:49-58`）：`at: number`(必) · `text: string`(必) · `channel?: 'stdout'|'stderr'|'log'` · `gapBefore?: true`
`JobChannel`（`view.ts:46`）：`'stdout' | 'stderr' | 'log'`（`log` 只给观察者，模型看不到）。

### 10.3 `todo` — 无路由

**0.1.7-rc.2 无 `todo` Remote namespace。** 唯一面是事件 + 投影：
事件 `todo/write`（`todo/tool-todo/src/types.ts:31`）：`{ todos: TodoItem[] }` —— **整表快照**，last-write-wins。
`TodoItem`（`todo/tool-todo/src/types.ts:19-25`，两字段全必填）：`content: string` · `status: 'pending' | 'in_progress' | 'completed'`（**三态**）。
**没有 `id`、没有优先级。** 投影 key `todos` = `TodoItem[] | null`（`:45`），`null` = 尚未写过。

---

## 11. 错误契约

### 11.1 线格式（精确）

`RemoteError`（`typert/protocol/src/remote-error.ts:12-31`）。跨 wire 的形态由 Gateway 归一化为 `ConnectionRpcFailure`（`api/gateway/src/index.ts:1351-1364`）：

```ts
interface ConnectionRpcFailure {
  readonly code: string
  readonly message: string
  readonly details: object
}
```

- 字段名是 **`details`**，**不是 `data`**（`client/connection/src/rpc.ts:19-23`）
- 三键全部必填，`details` 恒为 object（可为空 `{}`），**从不为 `undefined`**
- 结构标记 `isDSHRemoteError: true` 只在进程内 Error 实例上，**不上 wire**
- 判别永远靠 `code`，绝不用 `instanceof`（`remote-error.ts:10-11`）
- 客户端重建为 `RemoteError` 实例后放进 `{ ok: false, error }`（`api/gateway/src/client/index.ts:448`）
- 非 `RemoteError` 抛出被折叠成 `code: 'gateway/internal'`, `details: {}`（`api/gateway/src/index.ts:1356-1363`）
- 客户端侧传输故障（非 2xx、rpcId 不匹配、WS 断开）**不进 `error` 分支**，直接 reject（`api/gateway/src/client/index.ts:453-460`）

### 11.2 `code` 取值域

`RemoteErrorCode = keyof RemoteErrorDetailsMap`（`typert/protocol/src/types.ts:58-59`），声明合并式扩展。

**基座 3 个**（`typert/protocol/src/types.ts:49-56`）：`gateway/bad-request` `{ issues?: object[] }` · `gateway/cancelled` `{}` · `gateway/internal` `{}`。

**Gateway 基础设施 20 个**（`api/gateway/src/remote-error-codes.ts:15-36`），`details` 全部是 `TypertGatewayFaultDetails`（`:8-13`）= `{ endpoint: string /* 必 */; field?: string /* 仅字段级失败 */ }`：
`gateway/ambiguous-endpoint` · `gateway/arguments-invalid` · `gateway/binding-invalid` · `gateway/context-failed` · `gateway/context-not-found` · `gateway/context-unavailable` · `gateway/definition-unavailable` · `gateway/input-invalid` · `gateway/invocation-unavailable` · `gateway/lookup-failed` · `gateway/lookup-not-found` · `gateway/lookup-unavailable` · `gateway/method-unavailable` · `gateway/protocol` · `gateway/provider-mismatch` · `gateway/result-invalid` · `gateway/service-unavailable` · `gateway/signature-invalid` · `gateway/uplink-overflow`

**session 域 17 个**（`api/session-controller/src/types.ts:202-236` + `core/session/src/types.ts:526-531`）：

`session/not-found` `{ sessionId }` · `session/provider-credentials-unavailable` `{}` · `session/provider-models-unavailable` `{ provider }` · `session/model-unavailable` `{ provider, model }` · `session/conflict` `{ sessionId, requestedCwd, existingCwd? }` · `session/projections-unavailable` `{}` · `session/writer-held` `{ sessionId }` · `session/agent-busy` `{ reason }` · `session/invalid-time-zone` `{ value }` · `session/workspace-attach-failed` `{ sessionId, workspaceId }` · `agent-preset/conflict` `{ sessionId, requestedPreset, existingPreset? }` · `session/attachment-invalid` `{ reason }` · `session/queue-item-not-found` `{ itemId }` · `session/steer-unavailable` `{ itemId }` · `session/title-invalid` `{ sessionId }` · `session/fork-unavailable` `{ sessionId }` · `workspace/not-found` `{ workspaceId }`（`workspace/workspace/src/types.ts:21`）

**subagent 域 8 个**（`subagent/subagent/src/control-types.ts:125-139` + `api/session-controller/src/types.ts:227-235`）：
`subagent/invalid-time-zone` `{ value }` · `subagent/parent-unavailable` `{ parentSessionId }` · `subagent/not-resumable` `{ childSessionId }` · `subagent/unauthorized` `{ childSessionId }` · `subagent/attachment-invalid` `{ reason }` · `subagent/delivery-unavailable` `{ childSessionId }` · `subagent/not-found` `{ parentSessionId, childSessionId }` · `subagent/catalog-diagnostic` `{ parentSessionId, childSessionId, reason: 'corrupt'|'unsupported'|'unavailable' }`

**其它域**：`job/not-found` `{ sessionId, jobId }`（`api/job-controller/src/types.ts:44`）· `llm/model-discovery-rejected`（`llm/llm/src/index.ts:645`）· `settings/rejected` `{ ns }` / `settings/conflict` `{ ns, expected, actual }` / `credential/rejected` `{ ref }`（`api/settings-controller/src/types.ts:16-27`）· `terminal/unavailable` `{}` / `terminal/control-unavailable` `{ reason: 'read-only'|'not-running' }` / `terminal/limit-reached` `{ limit }`（`api/terminal-controller/src/types.ts:8-12`）· `workspace-file/not-found` 等 8 个（`api/workspace-files/src/types.ts:156-171`）· `plan/invalid-address` / `plan/unavailable` / `plan/not-found` / `plan/read-failed`（`client/ui-plan/src/client/plan-resource.ts:12-18`）。

### 11.3 HTTP 状态码 ↔ code 对应

见 §0.5。**核心结论：不存在映射。** 业务 `code` 一律在 HTTP 200 的 `result.error.code` 里；HTTP 状态码只反映传输层（鉴权/路由/编码/体积）。

---

## 12. 控制台最小集建议

### v1 必接（7 条）

| # | 通道 | 端点 | 理由 |
|---|---|---|---|
| 1 | RPC | `session/list` | 会话列表底座 |
| 2 | RPC | `session/create` | 新会话 |
| 3 | **STREAM** | `session/follow` | 气泡流命脉；唯一能拿到流式 token 的路径 |
| 4 | RPC | `session/prompt` | 发消息 |
| 5 | RPC | `session/cancel` | 停止 |
| 6 | **EVENT** | `$events` | 审批 + 提问的唯一往返通道（§4、§5） |
| 7 | RPC | `session/page` | 上滑加载历史 |

配套必须实现的客户端能力：mux WebSocket 客户端（§0.3）、`$events` 生命周期（§0.4）、`assistant-stream` 的 `revision` 连续性校验（§3.3）。

### v1 建议接（4 条，成本低收益高）

| # | 通道 | 端点 | 理由 |
|---|---|---|---|
| 8 | RPC | `session/modelCatalog` | 零硬编码的模型选择器；App 必须有 |
| 9 | RPC | `session/selectModel` | 与 8 配套 |
| 10 | RPC | `session/rename` | 长按改名 |
| 11 | **STREAM** | `session.control` | 跨会话状态（running / 子代理计时 / todo / 上下文占用），一次开流覆盖全局 |

`session.control` 的 `values` 已经顺带给了 `modelSelection`、`contextPressure`、`contextBreakdown`、`tokenUsage`、`subagentCatalog`、`todos`、`sessionStats` —— **§7 / §8 / §9 的数据全部从这条流来，不需要额外路由**。

### 可先不接

| 端点 | 理由 |
|---|---|
| `session/search` | 需要 `@deepseek-ai/dsh-session-query` 部署；长尾 |
| `session/fork` | 交互复杂（atSeq 选择），v1 可只支持「最新前缀」省略 `atSeq` |
| `session/updateQueue` | 队列编辑 UI 是长尾；`mode:'steer'` 需要 `agent.status === 'running'`（`commands.ts:477-479`） |
| `session/attachment` | 图片回读；v1 只发不发读 |
| `session/projections` | 若已接 `session.control` + `follow` 首帧投影，此路由冗余 |
| `session.attachment` / `fileUploads.upload` | 文件上传链路（`receiptId` 机制）长尾 |
| `session.openWorkspacePath` / `workspacePathApplications` / `canOpenWorkspacePath` / `workspaceDesktop` | 桌面端专属，手机端无意义 |
| `subagents.prompt` / `subagents.interruptByParent` | 需要父会话在线（§9.2）；App 只读展示子代理即可 |
| `job.*` | 后台任务面板，独立功能块 |
| `skills.list` / `fileReferences.list` / `commands.execute` | 桌面 UI 专属 |
| `session.initializeDefaultModel` | 引擎自身启动路径调用 |

### 已知长尾 / 陷阱

- **`session.export`、`sessions.list`、`todo` 路由、`subagent.catalog` 路由、context/token 系列事件** —— 在 0.1.7-rc.2 **全部不存在**。上下文/用量/子代理目录**只以投影形式存在**（§7.1、§8.1、§9.1）。
- `SessionSummary.projections.kind === 'cached'` 时，`asOfSeq` 属于缓存记录自己的序列空间，**不可**与已连接会话的基线比较（`types.ts:59-66`）。App 做增量合并时必须先看 `kind`。
- `values` 里缺 key = 能力不存在，**不是零值**（`types.ts:75-77`）。
- `contextPressure` 三个字段非原子，换模型时会短暂配对不一致（§7.2）。UI 需容忍。
- `todo/write` 是整表替换，无稳定 id —— diff 时要按整表处理，不能按 id 合并（`todo/tool-todo/src/types.ts:19-25`）。
- `ask_user_question` **没有 skip 字段**（§5.2），跳过语义由 App 自行实现（省略该 id / 空 `selected`）。
- `approval` 的 `unavailable` 是 fail-closed 语义，App 永不应主动回这个值（`user-approval/src/types.ts:28-32`）。
- `follow` 的 `assistantStream` 一旦请求就必须回 baseline（`client/transport.ts:186-192`）；`assistant-stream` 帧 `revision` 跳号必须触发**重连**而非继续消费。
- `plan-review` 的判定是 6 个条件的合取（§5.4）；任一不满足就退回通用问题流，answer 编码不变。
- `subagentCatalog` 条目**没有** `parentSessionId` 与运行状态（§9.1）；父子关系由「该投影属于哪个 Session」隐含。
- 一个 `origin: 'subagent'` 的子会话**不能**用 `{ kind: 'session' }` 打开，必须走 `{ kind: 'subagent', ... }`（`history.ts:347-353`）。
