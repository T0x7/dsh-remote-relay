# 引擎缺陷：工作区成员资格在读取时过滤，会话随机消失

**报告日期**：2026-10-05
**发现方**：dsh-remote-relay App 真机 E2E（D-057）
**引擎**：`@deepseek-ai/dsh-root` 0.1.7-rc.2（`/opt/homebrew/lib/node_modules/@deepseek-ai/dsh-root`）
**复现机器**：macOS arm64，`dsh-root web --host 127.0.0.1 --port 3080`（PID 6616）
**严重度**：功能正确性 —— **会话会随机出现在列表里又消失**，不是性能问题
**状态**：待 host-app / dsh-root 处理

---

## 1. 现象

App 的工作区列表里，「定时任务」这个工作区的会话数**持续乱跳**，跨度 35~94：

```
09:20:31  59      09:23:29  57      09:26:32  60
09:20:37  62      09:23:34  54      09:26:36  63
09:20:43  39      09:23:39  55      09:26:40  68
09:20:49  46      09:23:44  48      09:26:44  58
09:20:55  34      09:23:49  61      09:26:48  61
09:21:01  46      09:23:54  72      09:26:52  64
09:21:07  64      09:23:59  84      09:26:56  58
09:21:13  80      09:24:04  89      09:27:00  58
09:21:19  62      09:24:09  73      09:27:04  61
09:21:25  44      09:24:14  54      09:27:08  58
```

96 秒 / 24 次采样，**标准差 15.2，无收敛趋势**。列表里不仅数字在跳，**具体哪些会话出现/消失也在跳**——用户正在看的那一页会凭空少掉几个会话。

---

## 2. 排除「慢」这个假设

第一直觉是「1944 个会话太多，读取慢导致读不全」。三条证据否定它：

**2.1 引擎的工作区调用不慢。**

```
$ time curl -X POST .../api/workspace/rename ...
real 0m0.058s
```

58 毫秒。若真是 1944 个会话拖慢响应，不可能这个数。

**2.2 曲线不收敛。** 「慢」的曲线应当单调趋平（缺口越来越小）。实际持续震荡：48 → 94 → 35 → 94 → 35。

**2.3 会话更少的工作区完全不动。**

| 工作区 | 会话数 | 最后一次 `updatedAt` |
|---|---:|---|
| jobs | 50~94 **每 4 秒变** | 0.0 分钟前 |
| news | 201 | 60.4 分钟前 |
| backtest | 139 | **11123.6 分钟前（7.7 天）** |
| workspace | 28 | 19.4 分钟前 |

若「会话多 → 慢 → 读得不全」成立，139 和 201 也该在抖。它们不抖。**唯一的区别是 jobs 还在被定时任务持续写入。**

---

## 3. 根因

### 3.1 磁盘上存的是全量，发出去的是现算的

`packages/workspace/workspace/src/entity.ts:101`：

```ts
get sessionIds(): readonly SessionId[] {
  return this.record.sessionIds.filter(id => this.host.sessionPath(id) === this.record.path)
}
```

`record.sessionIds`（磁盘）是全量。`WorkspaceView` 走的是这个 **getter**，每次读都现算一遍过滤。

### 3.2 过滤依赖一个正在被填充的懒索引

`src/index.ts:184`：

```ts
sessionPath: id => this.sessionPaths.get(id),
```

`sessionPaths` 是个 Map，靠 `indexHeader()` 逐个填充。而 `indexHeader`（`src/index.ts:851`）对**每个会话头**都做一次系统调用：

```ts
const path = await realpathNormalize(header.cwd)   // realpath syscall
if (!(await stat(path)).isDirectory()) { ... }     // stat syscall
```

1944 个会话 = 3888 次系统调用，**这就是「每 4 秒」的来源**。

### 3.3 未命中即丢弃

`sessionPath(id)` 在索引未覆盖时返回 `undefined`，而

```ts
undefined === '~/.dsh-host/data/jobs'   // false
```

于是那个会话被**过滤掉**。读操作和索引在赛跑：

- 读的那一刻，某批会话刚进 `sessionPaths` → 可见
- 下一次读，另一批还没进 → 消失
- 下一批进来 → 又回来

实测每次采样都是 **±40 的大进大出**，而**归档集合纹丝不动**（`global.archivedSessionIds` 同期 +1 −0，因为它读 `global` 表，不走这个过滤）：

```
09:23:34  n=54  | 会话 +32 -35 | 归档 +0 -0
09:23:39  n=55  | 会话 +34 -33 | 归档 +0 -0
09:23:44  n=48  | 会话 +40 -47 | 归档 +0 -0
```

那些「新出现」的会话，**在整个注册表里原本都不存在**——它们是重新从 `~/.dsh-host/data/jobs/`（1944 个目录）扫出来写回的。峰值 76，离 1944 差 25 倍。

---

## 4. 建议修复

**首选（1 行）**：`sessionPath` 未命中时**不过滤**。

```ts
get sessionIds(): readonly SessionId[] {
  return this.record.sessionIds.filter(id => {
    const path = this.host.sessionPath(id)
    // 索引未命中 ≠ 不属于本工作区。宁可多显示，不可少显示——
    // 「会话随机消失」是正确性故障，「多显示一个」只是排序问题。
    return path === undefined || path === this.record.path
  })
}
```

**兜底**：把 header 索引从懒填充改成「服务启动全量 + 持续增量」——`[Service.init]` 里已有 `replaceHeaderIndex(await this.listStoredHeaders())`（`src/index.ts:211`），但之后新增的会话没被持续补进 `sessionPaths`。

**另建议**：`realpathNormalize` + `stat` 的结果可按 `(cwd, mtime)` 缓存，避免 1944 个会话每次都打两次 syscall。

---

## 5. 复现步骤

```bash
# 观察工作区成员数与更新时间（每 4s 采样）
cd ~/.dsh/storages && python3 -c "
import json,time
for i in range(24):
    d=json.load(open('workspace.json'))
    jobs=[w for w in d['tables']['workspaces'].values() if w['path'].endswith('/data/jobs')][0]
    print(time.strftime('%H:%M:%S'), len(jobs['sessionIds']), jobs['updatedAt'])
    time.sleep(4)
"
```

观察点：数字持续乱跳、标准差大、无收敛趋势；同时 `global.archivedSessionIds` 基本不动。

---

## 6. 对 App 侧的影响

App 已做的降级（**不修根因**）：数据不稳定时不显示数字、加「同步中」提示、列表不因行数变化而重建。

**但会话随机消失本身是引擎的功能缺陷，App 无法从客户端修**——客户端拿到什么就显示什么。这条应该和 `session/list` 劣化（`docs/internal/engine-session-list-degradation-report-20261004.md`）一起排优先级：**后者是慢，这个是错。**
