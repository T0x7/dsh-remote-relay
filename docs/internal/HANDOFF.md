# HANDOFF · 交接说明（2026-09-30）

> 面向接手本仓的开发者（人或 agent）。读完这一份就能接上。

## 一句话现状

三包 monorepo（server relay + client 隧道库 + dsh 插件），代码、测试、部署文档齐备，
尚未发布到 npm；四处 `repository.url` 已改成公网地址占位符，见 §1。

## ⚠️ 接手先做这三件事

### 1. 仓库地址已指向公网（完成）

公开仓库：**https://github.com/T0x7/dsh-remote-relay**

四个 `package.json`（根 / `client/` / `server/` / `plugin/`）的 `repository.url`
原指向本机 Gitea（一个仅本机可访问的私有远端），现已统一改为：

```
https://github.com/T0x7/dsh-remote-relay.git
```

`origin` remote 同址。`client/README.md` 的克隆命令与
`.github/ISSUE_TEMPLATE/config.yml` 的安全报告 / Discussions 链接也已同步。

⚠️ **分支名**：公开仓库建出来时默认分支是 `master`，本仓已对齐为 `master`
（CI 也随之改成只监听 `master`）。

⚠️ **历史**：公开仓是**压成 1 个初始提交**的——开发期 106 条提交里有 3 条消息带了
本地环境痕迹（`/Users/<用户名>`、`HTTPS_PROXY` 端口、Docker 网段），不打算随首次发布
公开。那 106 条历史只保留在本地归档分支 `archive/full-history` 上，**不要 push 它**。
完整清单见 §6。

### 2. 包名已经进 git 历史，改名代价高

| 包 | 名称 |
|---|---|
| server | `dsh-remote-relay` |
| client | `dsh-remote-relay-client` |
| plugin | `dsh-remote-relay-plugin` |

三个名均**未被 npm 占用**，可发。plugin 原拟 `dsh-remote-plugin`，已被他人占用（另一个同名产品），故改用现在这个名字。**包名不要随手改**——进了 git 历史和 npm 生态后难改。

### 3. 跑一次全量验证

```bash
pnpm verify
```

一条命令做 install → build → test，并直接检查 `plugin/lib/client.js` 的 lazy-CJS 契约（唯一 factory、id 为包名、无 ESM 语法、不直取 `@deepseek-ai/dsh-client-*`）。**跳过的层它会单独列出**——绿灯加跳过不等于全绿，别误读。

### 4. 开发历史不在公开仓里

公开仓 `T0x7/dsh-remote-relay` 是**压成 1 个初始提交**发布的。开发期 106 条提交
保留了完整推导过程（为什么隧道只有一份、为什么 `enabled` 默认关、契约抄录翻过的车），
但其中 3 条提交消息带了本地环境痕迹，随首次发布一并公开不合适：

| 提交 | 日期 | 痕迹 |
|---|---|---|
| `606f5d18` | 2026-10-08 | 消息体写了 `/Users/<用户名>/…` 的真实家目录前缀 |
| `0c2b296a` | 2026-10-05 | 消息体写了 `HTTPS_PROXY=127.0.0.1:7897` 本地代理端口 |
| `3327740f` | 2026-10-05 | 消息体写了 `0.0.0.0:8080` 与 `172.28.0.0/24` |

**没有**任何密钥、token、真实 relay 域名或 VPS 地址进过历史（`*.pem` / `.env` /
证书从未被提交过）。这三条本身也不致命——真要修，`git filter-repo` 只改消息体即可；
选择压成单提交是因为那 106 条里最有价值的是**设计决定**而非时间线，而决定都写进了
本仓文档（`CONTRIBUTING.md`、勘误表、`app/PROGRESS.md`）。

那 106 条历史保留在本地分支 **`archive/full-history`** 上，仅供参考：

```bash
git log archive/full-history --oneline | head   # 查得到
# 但不要推：git push origin archive/full-history   ← 会把痕迹一起公开
```

## 测试现状与分层

| 包 | 结果 |
|---|---|
| server | 90 passed（90） |
| client | 13 passed（13） |
| plugin | 38 passed / 15 skipped（53） |

plugin 的 15 个 skip 是**设计行为**——缺依赖时打印原因而非失败：宿主半边（8，需 devDeps）、构建产物（6，需先 `pnpm build`）、loader REAL-composition 主体（1，需 `dsh-loader-smoke` + dsh 在 PATH）。装完依赖 + 构建后应全部转绿，届时 **0 skip 才算验证通过**。

分层依据 dsh 官方测试规范（产品可见插件必须用真实 Loader 启动测试专用 `cordis.yml` 做 REAL-composition 测试，手工 `ctx.plugin(...)` 不算数）。官方工具是 `@deepseek-ai/dsh-loader-smoke`（已发 npm）。

## 接手前必须知道的三个设计决定

### ① tunnel 只有一份，在 client/ —— 别拷贝

`plugin/` 从 `client/` import `RemoteTunnelClient`，不 vendor 一份。历史上出现过两份实现分叉 289 行（净 +96）的事故，且分叉方向是旧副本丢失了跨进程配对收养逻辑。拷贝式管理就是那个失败模式的现场。

### ② 本仓不耦合任何私有部署 —— 别把耦合加回来

- server 不注册任何特定部署的显式路由前缀（`/*` 通配 + 全局 `onRequest` 闸门已覆盖全部行为，测试证实）
- WS 桥接路径白名单是配置项 `RELAY_WS_BRIDGE_PATHS`（CSV，默认空），不是硬编码清单
- client `tokenRewritePrefixes` 默认空，按需配置
- plugin `AUTH_PREFIXES` 只含 `['/api/', '/dsh-remote/']`
- tsconfig 不含任何仓外 path alias；需要 dsh 类型时一律用 npm 上的 `@deepseek-ai/*` 包

**约束**：代码、构建、路由、配置都不得引用私有仓路径或私有路由名。

> 例外说明：`server/live-smoke.mjs` 默认读 `~/.dsh-host/engine.token`——这不是私有耦合，是 dsh 引擎自身硬编码的 token 落盘位置（上游 `browser-auth.ts` 同路径），脚本提供 `DSH_ENGINE_TOKEN_FILE` 环境变量覆盖。

### ③ `enabled` 默认 `false`

装上插件**不会**自动开公网隧道。管理员须在设置卡里显式开启。改这个默认值等于让所有安装者自动暴露本机引擎，不要顺手改。

## 改代码前必读的两条不变量

- **DRIFT-1**：tunnel 实现只在 `client/src/tunnel.ts`。要改 tunnel 就改那里，不要在 plugin 里加一份。
- **DRIFT-2**：`/dsh-remote` 路由前缀是三方契约——plugin `ROUTE_PREFIX`、server 路由表、client `tokenRewritePrefixes`。改名要三处同批。

## 装完看着"成功"但没生效？先读这份

宿主升级 DSH 后，插件容易在宿主里报「异常」，或 profile 安装退出 0 却装着旧文件。
**判据不是退出码，是磁盘上的文件和引擎探针。**
完整排障流程见 [`../profile-install-troubleshooting.md`](../profile-install-troubleshooting.md)，
里面记了三个已踩过的坑，最阴的一条是：**改完代码不升 `plugin/package.json` 的
`version`，pnpm 会判定 up to date、压根不解压新 tarball**——退出码 0，装的是旧的。

## 发布顺序（发 npm）

**硬约束：client 先于 plugin。** `plugin` 的依赖 `dsh-remote-relay-client` 是 `workspace:*`，打包安装后按包名解析——client 不在 npm 上，plugin 就装不上。server 相对独立，任意时点可发。发前 checklist：

1. ~~四处 `repository.url` 换成公网地址~~ —— **已完成**，现指向 `T0x7/dsh-remote-relay`（见 §1）
2. `pnpm verify` 全绿 0 skip
3. `pnpm --filter <pkg> publish`（`prepare` 会在发布时自动构建）

## 仍未完成

- `npm publish`（三包，client 先）；README 目前走的是「从源码构建」路径，见 `client/README.md` / `plugin/README.md`
- 公网 VPS relay 部署（`docs/deploy.md` 有完整手册：TLS 自签 + certbot standalone + 续期）。**当前 VPS 跑的是 10/5 旧构建**，协议已落后 v3.199 代际——重部署时顺手升级
- 配对去重特性（同机器重配对不再翻倍卡片）：设计稿见 [`pairing-dedupe-design.md`](pairing-dedupe-design.md)
- 首次推送后确认 GitHub 侧默认分支是 `master`（仓库建出来时设的是 `master`，与本仓一致，通常无需改动）

> compose 项目名已从旧名改为 `dsh-remote-relay`（`server/docker-compose.prod.yml`）。
> **已经在用旧项目名部署过的机器，升级前必须先迁移数据卷**，否则 compose 会派生一个
> 空卷，relay 状态与手机配对全部读不到——该文件头部记录了这个坑的成因。迁移：
>
> ```bash
> cd <旧部署目录>
> docker compose -f docker-compose.prod.yml down      # 用旧项目名的那份配置
> docker volume rename <旧项目名>_relay-data dsh-remote-relay_relay-data
> # 再把仓库里新的 docker-compose.prod.yml 放回去，然后：
> docker compose -f docker-compose.prod.yml up -d --build
> # 验证配对还在：docker compose exec relay ls -l /data
> ```
>
> `docker volume rename` 需要 Docker 23+。更低版本的办法是把旧卷的数据拷进新卷，
> 但**先确认卷里到底是什么**再动手——它同时存着 relay 状态与审计日志。
