# 缺陷报告：`session/list` 挂起，手机端无法打开会话列表

- 报告人：dsh-remote-relay E2E 现场（Mavis）
- 日期：2026-10-04
- 严重级：Blocker
- 影响：手机上打不开会话列表；新会话的上下文投影取不到；已修的多个客户端行为无法验收
- 环境：dsh-host-app 内嵌引擎（App 形态，engine PID 48762，cwd = `dsh-host-app/Contents/Resources/engine`）

---

## 1. 现象

`session/list` 永不返回。客户端最终表现：

- 手机端：`gateway/internal · engine RPC session/list returned HTTP 504`，用户只能反复点「重试」
- 同一引擎上，**其他所有 RPC 都正常**

已持续 **2 小时以上**（10:50 → 12:52），跨 App 重启、跨 App 重装。

## 2. 关键判定：不是链路、不是 relay、不是数据量

按「先排除」逐层验证，每一步都做了对照：

| 探针 | 路径 | 结果 |
|---|---|---|
| A. 直连引擎 HTTP | `POST 127.0.0.1:3080/api/session/modelCatalog` | **200 OK（秒回）** |
| B. **直连引擎 HTTP** | `POST 127.0.0.1:3080/api/session/list` | **20s 超时** |
| C. **直连引擎 mux** | `ws://127.0.0.1:3080/api/remote.mux` → `session/list` | **60s 无响应** |
| D. 引擎健康端点 | `GET /dsh-host/healthz` | **200 OK** |
| E. relay 隧道 | `GET /dsh-remote/session` | `{"tunnel":{"state":"connected","relayUrl":"https://<relay-host>"}}` |
| F. relay 云端 | `GET https://<relay-host>/health` | **200 OK** |
| G. 手机 → LAN relay | `lsof` 53091 → 52984:8080 | **ESTABLISHED** |
| H. relay 插件实体 | `~/.dsh/profiles/web/node_modules/dsh-remote-relay-plugin` | version **0.1.1**，与 `package.json` 声明一致 |

**B/C 是决定性的**：它们**直连引擎本机 3080 端口，不经过 relay、不经过插件、不经过手机**。同一连接上 `modelCatalog` 正常返回，`session/list` 超时。

→ **不是连接问题，不是 relay 插件问题，是引擎 `session/list` 这一个方法卡住。**

## 3. 也不是「会话太多」这么简单——但很可能是它

第一反应是 1567 个会话太多，于是查了实际目录：

```
~/.dsh/sessions/  mindepth2 maxdepth2 type d   →  2273 个会话目录
其中最近 10 分钟内被写过的                     →  11 个（不是全局写锁风暴）
```

单个任务 `job-tidy-pump` 就堆了 **578 个会话目录**（`find … -name "job-tidy-pump-*" | wc -l` = 578），
增速可见于引擎日志：

```
[dsh-export:tidy-pump] 已导入 job-tidy-pump-20261004-112634
[dsh-export:tidy-pump] 已导入 job-tidy-pump-20261004-113143
[dsh-export:tidy-pump] 已导入 job-tidy-pump-20261004-122431
[dsh-export:tidy-pump] 已导入 job-tidy-pump-20261004-122635
```

所以不是"1567 条 JSON 太大"这么单纯，而是**要遍历 2273 个目录、对每个 stat/读锁、其中还夹着高频新建的会话**。

## 4. 卡点位置

`api/session-controller/src/index.ts:245-256`：

```ts
@Remote('list')
async list(_request: SessionListRequest, signal: AbortSignal): Promise<SessionListValue> {
  return { items: await this.listState.list(signal) }
}
```

**证据表明请求在到达这段业务代码之前就被堵住了**：引擎日志
（`~/.dsh-host/data/reports/.state/dsh-web.log`，1,415,713 行）里**搜不到任何 `session/list` 的记录**——
没有 `session/list`、没有 `listState`、没有任何与之相关的日志行。

也就是说，卡点在
**网关分发（`api/gateway`）→ 插件（`api/session-controller`）之间**，
或 `listState.list()` 内部读取会话元数据/持久化的那一层（`sessionPersistence.stat` / 会话目录扫描）。

## 5. 附带的协议问题（次要，但建议一并处理）

`session/list` 的请求形状是**保留的空对象**：

```ts
// index.ts:252 —— 参数名写作 _request，cursor 被实现忽略
async list(_request: SessionListRequest, ...)
// types.ts:264-266
export interface SessionListRequest { readonly cursor?: string }
```

**`cursor` 声明了但被忽略**，所以服务端没有任何分页能力，客户端只能一次性拿全部 2273 条。
对比：`session/search` 有真分页（`SESSION_SEARCH_RESULT_LIMIT = 20` + `hasMore`）。

这让 504 无解：即便修好不挂死，全量返回 2273 条 `SessionSummary`（含 `projections`）对手机也很重。

**建议二选一**：
1. 让 `cursor` 真正生效（真分页），或
2. 增加一个不带 `projections` 的轻量列表（`SessionSummary.projections` 在类型上**本就是可选的**，
   说明引擎有能力不带，只是当前实现带了）；列表页不需要 projections。

## 6. 复现步骤

```bash
# 1. 引擎正常时
curl -s -X POST http://127.0.0.1:3080/api/session/modelCatalog \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"x","method":"session/modelCatalog","payload":{"args":{}}}'
# → 200，秒回

# 2. 同一个连接上换 list
curl -s --max-time 20 -X POST http://127.0.0.1:3080/api/session/list \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"x","method":"session/list","payload":{"args":{"_request":{}}}}'
# → 挂住，20s 无响应

# 3. 会话目录规模
find ~/.dsh/sessions -mindepth 2 -maxdepth 2 -type d | wc -l
find ~/.dsh/sessions -mindepth 2 -maxdepth 2 -type d -name 'job-tidy-pump-*' | wc -l
```

引擎侧建议打开 list 调用的 trace（当前日志完全无痕迹，是定位最大的障碍）。

## 7. 客户端侧已做的处理（供交叉参考，非本缺陷的责任方）

在 dsh-remote-relay 侧，针对这个 504 已经做了三件事，都已测试通过，可作为复现后的对照：

- **D-037**：会话列表失败后自动退避重试（2s → 4s，两次为限），不再只能靠用户手点
- **D-037**：列表渲染上限 60 行 + 顶部明示「只显示最近 N 个（共 M）」（因为分页不可用，客户端只能裁）
- **D-039**：HTTP 504 现在映射为独立错误码 `engineTimeout`（文案「引擎处理超时，正在重试」，
  `RetryPolicy.autoBackoff`），不再笼统显示「引擎返回了未知错误」

所以修好引擎侧之后，客户端无需再改即可正常出列表。

## 8. 一并提醒：还有一个待确认项

今天的另一份报告（`docs/internal/vendor-build-defect-report-20261004.md`）是 vendor 构建产物不一致导致 60 个插件未激活的问题，**已由开发修复并验证通过**（控制面恢复后本缺陷才可复现/观察）。若修复过程中动过 `api/session-controller` 或其依赖，建议顺带回归本缺陷。
