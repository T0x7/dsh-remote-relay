# 引擎 RPC 勘误表（真机实证）

> 本项目所有 `/api/*` 引擎调用都由 `app/packages/dsh_remote_core/lib/api/engine.dart`
> 手写封装。**手抄契约必错**——本表逐条列出真机（2026-10-08 前后）实证的
> 正确信封，与常见错误写法对照。
>
> 验证方式优先级：① 打真实响应 dump 逐字段看；② 读引擎源码
> （`host-app/vendor/deepseek-harness/`）；③ 传空 args 的**零副作用**探针
> 读 descriptor 报错。**优先级 ① > ② > ③**，永远别只靠文档。

## 通用形状

- 请求：`POST /api/<endpoint>`，信封
  `{type:"client-request", rpcId, method:"<endpoint>", payload:{args:{…}}}`。
- 大多数业务端点的 args **按端点声明的参数名包一层**：通常 `request`
  （`session/list` 例外，用 `_request`）。
- **例外（易错）**：`$events/result` 的 args 是**裸对象**，无 `request` 包装。

## 逐端点勘误

| 端点 | args | 响应 | 易错点 |
|---|---|---|---|
| `session/prompt` | `{request:{sessionId, requestId, prompt, …}}` | ok | `requestId` 幂等：撞已处理 id 会 ok 但消息丢弃（D-077）|
| `session/list` | `{_request:{}}` | `{items:[…]}` | 包名是 **`_request`** 不是 `request` |
| `session/page` | `{request:{address:{kind:"session",sessionId}, throughSeq}}` | `{records:[…]}` | `address` 必带 `kind`；throughSeq 嵌在 `request` 里 |
| `$events` (stream) | `{}` | 帧流 | 开流返回 `ready` 帧带 `clientId`；换代即换 clientId（D-078）|
| `$events/result` | **`{clientId, eventId, outcome}` 裸对象** | ok | **多包一层 `request` → `gateway/internal`，审批永远不生效（D-078）** |
| `pluginInventory/list` | `{}` | `{entries:[…]}` | 只读清单 |
| `pluginManager/listPlugins` | `{}` | `[{entryId,moduleName,enabled,fiberPhase,patchId\|readOnlyReason,meta}]` | `meta.title` 可能是**本地化 Map** `{en,zh}`（D-081）|
| `pluginManager/listBundles` | `{}` | `[{name,version,enabled,installed,rows:[…],readOnlyReason?}]` | 用户视角（16 个包）|
| `pluginManager/setPluginEnabled` | `{id, enabled}` 裸 | `{changed, application}` | 裸对象；`application` 可能 `restart-required` |
| `pluginManager/setBundleEnabled` | `{name, enabled}` 裸 | `{changed, application}` | 同上 |

## 失败码速查

| code | 含义 | 处置 |
|---|---|---|
| `gateway/internal` + "invalid Remote event result" | `$events/result` 信封形状错 | 去裸对象 |
| `gateway/arguments-invalid` | args 键与端点 descriptor 不符 | 用零副作用空-args 探针读 descriptor |
| `session/agent-busy` | 子会话被 agent 占用 | 提示用户从主会话操作 |
| `engine/internal` + "atomic-wrote … lock" | 引擎侧 profile 写锁泄漏 | 引擎 bug，重启引擎 |

## 幂等与代际（两个静默失败源）

- **requestId 幂等**：`session/prompt` 用 client 铸的 id 去重。**跨进程必须
  唯一**（掺启动时间戳），否则 ok=true 但消息永不落库。
- **`$events` 代际**：网关只接受「接过该投递的那一代连接」的结果。客户端重开
  事件流 = 换代；换代的旧 clientId 提交的结果**静默丢弃**。应答前等当前代
  `ready`，失败重订并重试一次。

## 复现手法（本项目验证真理的标准动作）

```bash
# 读引擎真实响应（逐字段 dump，别手抄文档）
curl -s -X POST http://127.0.0.1:3080/api/<endpoint> \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"x","method":"<endpoint>","payload":{"args":{}}}'

# 零副作用探针写路由的参数名（空 args 让 descriptor 报错）
curl -s -X POST http://127.0.0.1:3080/api/<write-endpoint> \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"x","method":"<write-endpoint>","payload":{"args":{}}}'
```

引擎契约的字段级引用见 [`engine-contract-m2.md`](engine-contract-m2.md)；
App 端踩坑的完整叙事见 [`app-field-notes.md`](app-field-notes.md)。