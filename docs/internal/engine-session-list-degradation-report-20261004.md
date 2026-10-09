# 引擎 `session/list` 性能退化（2026-10-04 夜）

**收件人**：host-app（引擎侧）
**报告人**：dsh-remote-relay App 侧（真机 E2E 门 2）
**严重度**：高 —— 已经**阻断** App 的核心用例（浏览/恢复会话）

---

## 1. 一句话

`session/list` 的响应时间在同一个下午里从 **15–17s 涨到 84.4s**，而中继的
WSS 代理上限当时是 **30s**。结果是 App 每次打开会话列表都拿到 **HTTP 504**，
功能等于不可用。

---

## 2. 实测数据（全部是今天，`dsh-host-app` 形态，PID 6587 / engine node PID 6616）

| 时间点 | 直连 `127.0.0.1:3080` | 响应体 | 会话数 |
|---|---|---|---|
| 21:0x（早先一次成功） | **15–17s** | 1.79MB | 1567 |
| 22:12 | **67.24s** | 1,804,237 B | 1583 |
| 22:3x | **84.63s** | 1,806,175 B | 1583 |
| 23:07 | **105.14s** | 1,807,576 B | 1585 |
| 00:50（两次连续） | **131.85s / 132.10s** | 1,822,668 B | 1591 |

两次连续测量相差 **0.2%**（响应体只差 1 字节）。所以：

**这不是「每次调用都在泄漏」的持续劣化，而是由累积状态决定的阶梯**——状态涨到某个量级，
耗时跳一级，级内高度稳定。排查时请按「找一个阈值」而不是「找一个泄漏」去想。

### 关键线索：耗时与会话数不成比例

```
会话数   1567 → 1591     +1.5%
耗时      15s → 132s     +780%
```

**会话数涨 1.5% 解释不了耗时涨 7.8 倍。** 所以「会话太多所以列不出来」只是表象，
真正的成本在别处，而且它随某种**独立于会话条数**的东西增长。

已知的候选（按可疑度）：

- **投影缓存**：`~/.dsh/storages/session_projcache.json` 已 3.26MB，而同目录的
  `session_projcache/` 实体目录停在 9 月 6 日。缓存可能持续增长而落盘没跟上。
- **每次 `session/list` 都要重算全部 projection**：响应里 78%（1.4MB / 1.8MB）
  是 `projections`，1581/1591 条都带。如果重算是 O(会话数 × 每条成本) 而
  成本本身又在涨，就是这个形状。
- **日志目录扫描**：`~/.dsh/sessions/` 与 `data/jobs`（1933 目录）、
  `data/reports`（6735 文件）都在增长，若 `list` 顺带 stat 了它们…

**客户端侧能提供的证据到此为止**——上面三条都需要在引擎进程里 profile 才能定，
`session/list` 目前的耗时也使得「二分查找」这种朴素办法不可行。

复现命令（直连，绕开中继以排除中继因素）：

```bash
TOKEN=$(cat ~/.dsh-host/engine.token)
curl -s -m 150 -X POST "http://127.0.0.1:3080/api/session/list" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"type":"client-request","rpcId":"p1","method":"session/list",
       "payload":{"args":{"_request":{}}}}' \
  -o /tmp/ls.json -w "http=%{http_code} bytes=%{size_download} time=%{time_total}s\n"
```

> 注：必须带 `client-request` 包络。裸打 `/api/session/list` 或缺 `method` /
> `payload` 会被 schema 拒掉（`gateway/bad-request`），那不是性能问题。

## 3. 会话构成 —— 1329/1583 是定时任务

```
总条数 1583
  job-*     1329   (84%)   ← judge / profiler / investigator 等 cron 产物
  session-*   43   ( 3%)   ← 真正的对话
  其它（裸 uuid 前缀）约 211
```

**这是首要嫌疑**：1329 条 job 会话是 cron 每次运行留下的产物，只增不减。
`session/list` 每次都要把它们全部物化并算 `projections`，成本随累积量线性上升。
响应体 1.8MB 里有 **1.78MB 是 `projections`**（占 84%）。

## 4. 对 App 的实际影响

中继当时的 `WSS_PROXY_TIMEOUT_MS = 30s`。引擎 84s ⇒ **每一次列表请求都必然 504**（D-045 已把两边提到 180s / 195s，此处记录的是改动前的事实）。

App 侧表现（真机截图 `.e2e/t12_after_d044.png`）：

```
引擎处理超时，正在重试
engine.timeout · engine RPC session/list returned HTTP 504
[重试]
```

D-037 的自动退避重试**无法自愈**——不是偶发，每次都必然超时，重试多少次都一样。

## 5. 建议（按性价比排序，App 侧不改）

> **2026-10-04 22:4x 更新**：第 4 条**已经做了**（D-045，中继 30s → 180s，
> App 35s → 195s，两处一起）。这只是**解封**——它让 85s 的响应能穿过中继，
> 不改变 85s 这个事实。1–3 仍然是真正的修复。

1. **让 `session/list` 支持「不带 `projections`」**（类型上 `projections` 本来
   就是可选的）。App 的列表页只要 `sessionId` / `updatedAt` / `running` /
   `turns`，不需要每条会话的上下文胶囊。预计 84s → 2–3s。
2. **给 job 会话设保留策略**（按时间/数量淘汰，或 job 完成后不留在主列表）。
   1329 条 cron 产物本身就没有浏览价值。
3. **真正实现服务端分页**。当前 `index.ts:252` 把请求参数写作 `_request`，
   `cursor` 被直接忽略，所以任何客户端都只能一次全量拉。
4. ~~把中继的代理上限从 30s 提到 120s~~ —— **已做（D-045，提到 180s）**。
   注意：只改中继不生效，App 自己的 `defaultCallTimeout` 会先掐断，所以两处
   必须一起动（`server/src/index.ts` 与 `engine_rpc.dart` 互为注释）。

## 6. 交叉参考

- 早先的同类报告：`docs/internal/engine-session-list-hang-report-20261004.md`
  （当时是挂死 2 小时+，今天早些时候修好后是 15–17s；本报告是**修好之后的
  二次退化**，量级不同，请分开看）
- App 侧已做的韧性：`app/lib/console/sessions/sessions_page.dart`
  （60 行渲染上限 + 如实报总数 + 退避重试）、`app/packages/dsh_remote_core/lib/api/error_code.dart`
  （`engineTimeout` 已正确区分，不再报「未知错误」）
