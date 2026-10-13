# dsh-remote-relay

[English](README.md) | [简体中文](README.zh-CN.md)

从任意位置访问本机上的 dsh 引擎——同时不把它暴露到公网上。

一套四件式的系统，用来安全地远程控制绑定在本机的 dsh 实例：

- **`server/`**（`dsh-remote-relay`）——加固过的反向代理 + WebSocket 中继，部署在一台廉价的公网 VPS 上（Docker compose 自带 nginx TLS）。它是公网边缘：TLS 终止、会话闸门、限流、只追加审计日志，以及带 webhook 告警的看门狗。
- **`client/`**（`dsh-remote-relay-client`）——无头 CLI／库，跑在引擎旁边的本机上。它通过 PSK 鉴权的 WebSocket 隧道**主动外连**到中继，并在本地承接被代理的 HTTP/WS 流量。零入站端口。
- **`plugin/`**（`dsh-remote-relay-plugin`）——dsh 框架插件。它是一层很薄的接缝：只负责配对二维码的设置卡片与路由注册，隧道本身委托给 `client/`。想在 dsh 界面里管理远程控制就用它；想在终端或服务单元里管理就用 CLI。
- **`app/`**（`dsh_remote_app`）——Flutter 远程控制 App（iOS + Android，一套代码）。扫同一个二维码配对，然后接着在这台机器上继续会话：流式对话、审批与提问卡片、任务、模型、上下文环、子代理团队。凭据存在平台钥匙串，中继 TOFU 固定，零遥测。见 [app/README.md](app/README.md)。

手机扫一个二维码（或打开一个签名 URL），落到中继源站，dsh 的 SPA 直接从那里加载——完整远程控制，而引擎的 PRIVILEGED 面仍然只监听 loopback。App 走同一套面配对，浏览器用不了的时候它照样能用。

```
phone ─HTTPS/WSS─→ nginx(TLS) ─→ relay (VPS) ~~~PSK tunnel /ws/dsh~~~ client ─→ dsh engine (127.0.0.1:3080)
                                    │
                                    ├─ session gate (signed URL / pairing cookie / Bearer)
                                    ├─ rate limit + readonly/query fences
                                    ├─ SQLite audit log (append-only)
                                    └─ watchdog (burst / probe / downtime alerts → webhook)
```

## 双闸门信任模型

1. **引擎闸门**——dsh 只绑定 loopback，且只对 Host 为 loopback 或 `--trusted-host` 条目的请求提供 `/api`；16 个 PRIVILEGED 方法（`settings.*`、`credentials.*`、`host.*` 等）始终只在 loopback 生效。
2. **中继闸门**——client 把受信 authority 钉进每一个被桥接的请求（`Host` 头），而中继在自己的健康检查／PSK 端点之外，每一条路径都要求凭据（签名 URL query、配对 cookie，或 `Bearer` 会话令牌）。

任何一道闸门失守，另一道仍然兜着：中继域名泄露了，没有配对它什么也服务不了；引擎则从不直接信任公网。

## 快速上手

**完整自托管教程（DNS、TLS、配对、排障）：[`docs/deploy.md`](docs/deploy.md)**——下面是精简版：

**1. VPS——把中继跑起来**

```bash
cd server
cp .env.example .env
#   RELAY_PSK=$(openssl rand -hex 32)
#   RELAY_PUBLIC_HOST=relay.example.com
bash deploy/gen-selfsigned.sh relay.example.com   # 或用 certbot
docker compose --profile tls up -d --build
```

**2. 本机——与中继配对**

```bash
cd client
pnpm install && pnpm build
dsh-remote-client pair --relay-url https://relay.example.com --psk <same RELAY_PSK>
# → 在终端打印二维码；用手机扫
```

**3. 本机——让隧道常驻**

```bash
dsh-remote-client serve --relay-url https://relay.example.com --psk <same RELAY_PSK>
```

`serve` 与 `pair` 顺序随意——`serve` 会在运行时接管 `pair` 铸出的配对（并在每次重连时重新登记它持有的全部配对）。

（用 `--trusted-host relay.example.com` 启动 dsh，好让它的围栏接受经中继桥接过来的流量。）

**另一种方式——在 dsh 界面里管理配对**

不想用 CLI，就把插件装进你的 dsh profile。它会加一张「远程控制」卡片（Plugins 面板里插件自己的页面，外加一个远程信道下依然可达的 Settings 导航分区），显示隧道状态并渲染配对二维码，生命周期挂在 `/dsh-remote/` 下：

```bash
# 还没上 npm —— 先从 checkout 打出两个 tarball，然后一起装
pnpm install && pnpm -r build && scripts/pack-local.sh   # → dist-local/*.tgz
dsh plugin --profile <your-profile> add \
  dist-local/dsh-remote-relay-client-<v>.tgz \
  dist-local/dsh-remote-relay-plugin-<v>.tgz
```

有两条仓库脚本覆盖了裸 `add` 不管用的场景：`scripts/dev-test-profile.sh` 造一个一次性的 profile 用于发版前验证，`scripts/install-into-profile.sh` 则装进桌面 App 真正启动的那个 profile（带备份与自动回滚）。两者都会替你设好 pnpm override 与 `dsh.profile.bundles` 条目——[各路径的作用，以及为什么 `dsh.profile.bundles` 不是可选项](plugin/README.md#install)。

然后在 profile 的 patch 层里填上同一个中继地址与 PSK——配置键见
[`plugin/cordis.patch.yml`](plugin/cordis.patch.yml)。中继起来之前先保持 `enabled: false`；忘记覆盖 PSK 会在中继侧 fail-closed，而不是开出一条通道。

完整手册：[`server/README.md`](server/README.md) ·
[`client/README.md`](client/README.md) · 线上协议：
[`docs/protocol.md`](docs/protocol.md) · 插件在宿主里显示「异常」，或装进 profile 后静默不生效（最常见的原因是：包在 `dependencies` 里，但名字没进 `dsh.profile.bundles`）：
[`docs/profile-install-troubleshooting.md`](docs/profile-install-troubleshooting.md)。

## 仓库结构

```
server/    relay server (Fastify + ws + SQLite; Dockerfile, compose, nginx template)
client/    tunnel client (headless CLI + library, vitest) — the tunnel's single source of truth
plugin/    dsh framework plugin (settings card + routes; depends on client/)
app/       Flutter remote-control app (Android + iOS) + dsh_remote_core (Dart client)
scripts/   repo tooling: ARB key check, secret scan, profile packaging
docs/      protocol + engine-RPC references + deploy guide
```

隧道实现**只有一份**，在 `client/` 里。插件是 import 它而不是内联一份拷贝，所以一次修复（例如跨进程配对接管）能同时到达两个消费方。协议类型在 server 与 client 之间是**刻意手工拷贝**的（它们一起演进，各自的测试套件会钉住这些共享形状——权威帧参考见 `docs/protocol.md`）。

## 安全须知

- 生产环境在检测到不安全的默认 PSK 或缺失 `RELAY_PUBLIC_HOST` 时拒绝启动（fail-closed）。
- 会话密钥存放在 `server/data/relay-state.db`——把那个卷当成密钥库对待。客户端的配对存放在 `~/.dsh-remote-relay/`（chmod 600）。
- 签名 URL 是基于 PSK 的 HMAC-SHA256，TTL ≤24 小时，并带一个绑定机器的 `mid` 哈希；过期链接 fail-closed。
- 看门狗会在鉴权失败突发、PSK 探测、代理错误突发、隧道宕机与审计库膨胀时发出 webhook 告警。

## 文档

标注 **中文** 的文档用中文写，其余为英文。这里标出来，是为了不让任何人以为点进去会看到英文说明、结果撞上一屏中文——底层文档本身没有改动，只是把语言声明出来。

- [`docs/protocol.md`](docs/protocol.md) — 隧道线上协议（权威帧参考）
- [`docs/engine-rpc-errata.md`](docs/engine-rpc-errata.md) — **引擎 `/api` RPC 勘误表**：
  实测正确的信封形状与易错点（写引擎客户端前必读）· **中文**
- [`docs/app-field-notes.md`](docs/app-field-notes.md) — Flutter app 真机踩坑与修复纪实 · **中文**
- [`docs/device-testing.md`](docs/device-testing.md) — **真机测试方案**：三层体系 +
  adb 控制真机手册 + 环境陷阱速查（跑回归前读）· **中文**
- [`docs/engine-contract-m2.md`](docs/engine-contract-m2.md) — 引擎契约字段级引用 · **中文**
- [`docs/deploy.md`](docs/deploy.md) — VPS 部署
- [`app/README.md`](app/README.md) · [`app/TESTING.md`](app/TESTING.md) — app 开发与验收 · **中文**

> 要写面向引擎那一侧的客户端？**先**读勘误表——这个项目里大多数集成 bug，根源都是一份真实引擎从未接受过的手工拷贝契约。

## 贡献

一条命令的验证路径（`pnpm verify`）与防泄漏要求见 [CONTRIBUTING.md](CONTRIBUTING.md)，基本规则见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

**发现安全问题？** 不要提公开 issue——按 [SECURITY.md](SECURITY.md) 走。

## 许可

MIT——见 [LICENSE](LICENSE)。