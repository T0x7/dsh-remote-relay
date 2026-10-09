# 交接：dsh-remote-relay 真机 E2E 发现的两条引擎缺陷

**日期**：2026-10-04 夜
**报告人**：dsh-remote-relay App 侧（真机 E2E 门 2）
**收件人**：host-app（引擎侧）
**引擎版本**：`@deepseek-ai/dsh-root` 0.1.7-rc.2（`dsh-host-app`，node PID 6616 监听 127.0.0.1:3080）

两条都**不需要协议改动**，App 侧也已经各自绕开了。列在这里是因为绕开不等于修好。

---

## 缺陷 1（高）：`session/list` 的耗时与会话数不成比例

### 现象

同一台机器、同一个接口，一个下午：

| 时间 | 直连耗时 | 会话数 |
|---|---|---|
| 21:0x | 15–17s | 1567 |
| 22:12 | 67.24s | 1583 |
| 22:3x | 84.63s | 1583 |
| 23:07 | 105.14s | 1585 |
| 00:50 | 131.85s / 132.10s | 1591 |

**会话数 +1.5%，耗时 +780%。**

00:50 的两次连续测量相差 0.2%（响应体差 1 字节），所以这是**由累积状态决定的阶梯**，
不是每次调用都在泄漏的持续劣化。排查请按「找一个阈值」而不是「找一个泄漏」去想。

### 已定位的证据：单条会话的投影重算

同一条 `POST /api/session/projections`（`args: { request: { sessionId } }`），
只换会话：

| 会话 | 耗时 |
|---|---|
| `session-f189bd9e-…`（当天新建的普通会话） | **0.033s** |
| `job-investigator-20261005-000717` | 0.972s |
| `job-scheduled-judge-20261005-000058` | 0.911s |
| `job-scheduled-judge-20261004-220047` | 0.885s |
| **`job-scheduled-judge-20260916-000020`（19 天前）** | **125.512s** |

**一条 9 月 16 日的会话，单独算一次投影要 125 秒**，而整个 `session/list` 只需 132 秒。
**单条就几乎吃满了整个请求。**

普通会话 33ms、job 会话 0.9s、超大 job 会话 125s——中间是断崖，不是连续增长。

### 一条相关线索（未证实）

`api/session-controller/src/list.ts:110-118` 里，列表行从 projections 里**只读了
两个字段**：

```ts
const projections = this.projectionsFor(session.header, session)
const metadata = projections?.values.sessionListMetadata
return {
  ...
  blank: metadata?.blank ?? session.seq === 0,
  ...(projections === undefined ? {} : { projections }),   // 整个挂给客户端
}
```

即：**读两个字段，附赠整个对象**。1581 条 × ~1KB = 1.4MB，占响应的 78%
（1.8MB 总量）。

而 `sessionProjectionCache.cachedSnapshot` 的接口文档写明它是
**"The zero-I/O listing read: whole values viewed straight from the stored rows"**，
`session-query/README.zh.md:152` 也写着「`listSessions` 保持轻量」。

**所以按设计它本该是轻量的。** 但我无法从客户端判断 `list` 内部的 `projectionsFor`
与 `session/projections` 路由是否共用同一条慢路径——**这需要在引擎进程里 profile**。

### 建议（按性价比）

1. **`session/list` 支持不带 `projections`**（类型上本就是可选的
   `SessionSummary.projections?`）。1.8MB → 0.4MB，且完全绕开重算。
   App 的列表页只需要 `sessionId` / `updatedAt` / `running` / `cwd`。
2. **让列表行走零 I/O 的 cached 路径**，即上表那两个字段真的只从存储行读。
   这是根因；第 1 条只是绕开。
3. **给 job 会话设保留策略**。`data/jobs` 1933 个目录、`data/reports` 6735 份，
   cron 一直在跑；`sessionIds` 长度合计 1332（占 1591 的 84%）。这些产物本身
   没有浏览价值。
4. 真正实现分页（长期正确解）。当前 `index.ts:252` 把请求参数写作 `_request`，
   `cursor` 被直接忽略，任何客户端都只能一次全量拉。

---

## 缺陷 2（中）：新会话的默认 cwd 落在 App 包内部

### 现象

在手机上新建会话（`session.create`）得到的会话，cwd 是：

```
~/Container/host-app/apps/host-app-desktop/dist/mac-arm64/
  dsh-host-app/Contents/Resources/engine
```

那是**引擎 App 包里打包的自身资源目录**（里面有 `.agents/skills`、`node`、
`python`、`scripts`、`vendor`），不是用户数据目录。

后果：用户在手机上开一个对话，agent 的工作目录落在 `dsh-host-app` 内部——
**App 一升级就被覆盖**，且那里没有任何用户数据。

### 为什么确定是 bug 而不是配置

同一台机器上引擎给**其他**会话分配的 cwd 全部正确：

```
~/.dsh-host/data/inbox
~/.dsh-host/data/jobs
~/.dsh-host/data/workspace
~/.dsh-host/data/market
~/.dsh-host/data/sim
~/.dsh-host/data/engines
~/Container/host-app/{news,jobs,workspace,trading,engines}
```

定时任务与已有会话都落在 `~/.dsh-host/data/*` 或仓库目录里，**只有
`session.create` 这一条路径的默认值落在 App 包内**。这与
`data/engines/README.md` 描述的「工作区 cwd 指向 data/」的意图也不一致。

### 建议

`session/create` 的默认 cwd 应当是用户数据目录（`~/.dsh-host/data/workspace`
或调用方显式传入），并且**在 App 升级路径下不得作为工作目录**。

---

## 附：App 侧已经做了什么（供交叉参考，非本报告的责任方）

- **超时**（D-045）：relay 30s → 180s，App 35s → 195s。**这是买时间不是修复**——
  引擎已到 132s，斜率约每 100 分钟 +27s，几小时内会再次越过 180s。
- **绕开**（D-047）：会话入口改为只读 `workspace/follow` 注册表，
  `session/list` 从关键路径上移除，真机从 132s 降到约 5s。引擎修好后，
  剩余的两处 `session/list` 调用（打开 App 自动恢复最近会话、主机页）会跟着好。
- 中继侧每次 504 都记 `wss_proxy_timeout` 审计事件，可用
  `relay-audit.db` 独立验证链路判断。
