# 引擎交接报告：工作区树「死会话行」——注册表幽灵 id 与绕过引擎的 journal 直写

- 日期：2026-10-06
- 报告方：dsh-remote-relay（App 侧）排查用户报告「dsh web 上部分会话无法进入对话框页面（如 scheduled-morning-xxx）」
- 影响面：dsh web 与 dsh-remote-relay App 的工作区分组树（两者消费同一注册表）
- 性质：**引擎 + host-app 双侧协同缺陷**，App 侧无独立修法（只能缓解）

## 0. 更正（2026-10-06 晚，host-app 侧已定位真因并修复）

本报告 §2 第 3 点「来源 A」的机制判断**有误**，已被 host-app 同日的
`docs/decisions/2026-10-06-dsh-import-header-title-invisible.md`（ADR，v3.273）推翻并修正：

- ~~「引擎没有目录 watcher，直写文件永不索引」~~ —— 不成立。引擎 `session/list`
  每次调用**零缓存全量重扫**目录树（v3.269 补丁注释原话），无需 watcher；同一条
  Python 导入路径写的 95 条 `job-*` 会话（scheduled-judge/alpha/paper-trade…）都被正常索引。
- **真因**：host-app 的会话导入器（`scripts/dsh_import_session.mjs`，v3.266 适配
  0.2.0 时）把 `title` 留在了 v4 header 白名单里，而 v4 契约已把 title 移到
  `session/title` 事件、对 header **严格校验**——`readHeader` 判 `malformed`
  （unexpected field title）→ `readGenerationHeader()` 返回 undefined →
  `listArtifacts()` **无日志静默 continue** → 文件在盘上、会话在引擎视角不存在。
  写端 `Session.create` 容忍该字段，所以写入器自己的自检也能过——双端都静默。
  （本报告上午 dump 的幽灵 journal 头部 `"title":"🤖 scheduled-morning…"` 即铁证，
  当时未识别；对照活会话 header 无 title 字段的差异就在眼前，漏判。）
- **修复**（host-app v3.273，当日落地）：写入器 header 不再写 title +
  落盘前加**读端同款** `readHeader()` 第二道校验（写端自检从此无法在读端会拒绝
  的文件上通过）+ 可见性审计脚本，零 vendor 改动。v3.274 继续收敛导出策略
  （SESSION_STRATEGY：'none' 的 job 不再导空壳）与留档卡内容构造器。
- 旧幽灵 journal 已被清理；本报告仍然成立的部分：**注册表侧**的幽灵 id（
  `.DS_Store` 混入、139 条 paper-backtest journal 删除后注册表从不修剪、
  `workspace/follow` 线上投影与磁盘文件可分叉），以及 App 侧 D-067 死行兜底的必要性。

## 1. 现象

dsh web 侧栏「定时任务」等工作区里，部分会话行（例：`job-scheduled-morning-20261006-083520`）可见但点击后无法进入对话页。

## 2. 结论（三层，全部实测）

1. **引擎不认识这些 id**。对幽灵 id 调 `session/page`：
   `{"ok":false,"error":{"code":"session/not-found","message":"session \"job-scheduled-morning-20261006-083520\" not found"}}`；
   同一时刻对活会话（`job-scheduled-judge-20261006-091023`）同端点返回 200。
2. **这些 id 来自工作区注册表** `~/.dsh-host/dsh-home/storages/workspace.json` 的 `tables.workspaces[*].sessionIds`。实测（10-06 ~10:00）：注册表共 **249** 个 id，其中 **154 个**在引擎 `session/list`（102 条）中不存在；7 个活会话反而是孤儿（不在任何工作区注册里）。
3. **幽灵的两个来源**：
   - **来源 A（host-app 任务进程绕过引擎直写 journal）**：`scheduled-column-*`、`advise*`、`daily-summary`、`report-warmup` 这几类任务的 journal 落盘在引擎 sessions 目录里（如 `dsh-home/sessions/--Users-someone-.host-app-data-jobs--/job-scheduled-morning-20261006-083520/session.v4.jsonl.zstd`），但事件序列只有 `turn/start → user/message → turn/end → session/title`（350ms 内写完），**完全没有引擎引导事件**（对比活会话 `job-scheduled-judge`：`permission/preset → sandbox/mode → approval/policy → agent/unattended → request/header → assistant/message → tool/*` 全链路）。即这些 journal 不是经引擎 `session/create` RPC 产生的，引擎（无目录 watcher）永不索引它们 → 引擎视角「不存在」。幽灵横跨引擎重启（00:00:57）前后，排除「启动扫描遗漏」。
   - **来源 B（注册表照单全收 + 从不修剪）**：注册表成员集合把 sessions 目录条目直接当会话 id 收录——`定时任务` 工作区里赫然有 **`.DS_Store`**；且 journal 被清理后 id 永不回收——`回测研究` 工作区 139 个 `job-paper-backtest-day-20260927-*` id 在磁盘上已无任何对应目录，仍留在注册表。于是死行持续累积（本次排查期间 153 → 154，实时在涨）。

## 3. 链路还原

```
host-app 定时任务(部分类型) ──直写 journal──▶ sessions 目录（引擎不感知）
                                   │
                                   ▼
              引擎注册表成员扫描把目录条目收进 sessionIds（含 .DS_Store）
                                   │
        ┌──────────────────────────┴──────────────────────────┐
        ▼                                                     ▼
dsh web / App 工作区树渲染出死行              引擎 session/list 永远不含这些 id
        │
   用户点击 → follow/page → session/not-found → 无法进入对话页
```

## 4. 附带观察（非本次根因）

- 部分树行显示「56年」时间戳（epoch-0 兜底）。这些 id 实测 LIVE（如 `1350a0f6-ac2b-…`），属 dsh web 对 updatedAt 缺失的另一处显示问题，与死行无关。
- dsh web 树在 workspace/follow 流持续重渲染下，完整页面快照多次超时——与 App D-057 记录的成员闪跳（`entity.ts:101` 读时过滤懒索引）同源的引擎行为在 web 侧的表现。

## 5. 修复建议

| 侧 | 建议 |
|---|---|
| host-app | 上述任务类型改走引擎 `session/create` RPC（radar/scheduled-judge 已是正确示范）。顺带解决这些会话没有标题投影的问题（journal 里已有 `session/title` 事件，引擎支持自动命名） |
| 引擎 | a) 注册表成员写入时校验会话存在性；b) 提供一次性 reconcile（对不存在 id 归档/清除）；c) 目录扫描忽略非会话条目（`.DS_Store` 等）；d) journal 删除时联动修剪注册表 |
| dsh web | 渲染树时对照 `session/list`，对不存在的 id 隐藏或置灰禁点，别渲染死行 |
| 立即缓解 | 对死行逐个「归档会话」（dsh web 行操作 / App 归档按钮同端点 `workspace/archiveSession`），把 id 移出分组视图；或由 App 一次性批量归档 154 条（**写注册表操作，需用户点头后执行**；引擎是否接受 not-found 的 id 待验证） |

## 6. 复现/取证命令附录

引擎本体：`127.0.0.1:3080`（`dsh-host-app/…/engine-launch.sh → bin.js web --port 3080`）；`8080` 是 relay（带配对墙）。会话落盘根：`~/.dsh-host/dsh-home/sessions/`。

```bash
# 会话列表（注意 args 必须包 _request）
curl -s -X POST http://localhost:3080/api/session/list -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"r1","method":"session/list","payload":{"args":{"_request":{}}}}'
# 幽灵 id 实证（session/page 的 args 包 request，且 throughSeq 必填）
curl -s -X POST http://localhost:3080/api/session/page -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"g1","method":"session/page","payload":{"args":{"request":{"address":{"kind":"session","sessionId":"job-scheduled-morning-20261006-083520"},"throughSeq":-1}}}}'
# journal 解包（Python 3.14 自带 zstd）
python3 -c "from compression import zstd; print(zstd.ZstdFile('<journal路径>').read().decode())"
```
