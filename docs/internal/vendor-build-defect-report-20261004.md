# 缺陷报告：dsh-host-app 内嵌 dsh vendor 构建产物不完整，引擎控制面全灭

- 报告人：dsh-remote-relay E2E 现场（Mavis）
- 日期：2026-10-04
- 严重级：Blocker（App 形态引擎控制面完全不可用，手机端无法配对）
- 影响版本：`apps/host-app-desktop/dist/mac-arm64/dsh-host-app`（vendor 产物批次 2026-10-03 13:45 / 打包 14:07；10/3 23:15 又有一次局部构建叠加）

---

## 1. 现象

dsh-host-app 启动后，内嵌 dsh 引擎（`Contents/Resources/engine`）HTTP 层存活，
但 dsh 控制面整体失效：

```
# 引擎 host-app 插件层正常：
GET /dsh-host/healthz → 200 {"ok":true,"engine":"host-app","version":"3.241.0"}

# web UI 打开即报错（浏览器渲染的错误页原文）：
Failed to load plugins
@deepseek-ai/dsh-api-remotes
web boot: 60 entries did not activate
@deepseek-ai/dsh-api-remotes: import failed: client-modules:
  require("@deepseek-ai/dsh-client-product-analytics/remote") missed the module table
  — not a platform seed word, not a materialized module, and no registered package factory
  (a build-time externals drift, or a dynamic dependency that did not arrive)

# 控制面路由全部不可用：
POST /api/session/list   → 挂起（无响应）
GET  /dsh-remote/session → 404（配对路由不存在）
（其余 remote.* 依赖的路由同理）
```

连锁影响（业务侧）：手机 App 的配对会话 TTL 过期后无法重新配对（配对链接由
`/dsh-remote/*` 出，已 404）；profile 层 relay 插件依赖的宿主 `remote.*` 服务全部
缺失，跟着挂不上；`session-controller`、`workspace-files`、`ui-deliverables` 等
60 个插件全部 `pending (waiting for services: remote.*)`。

## 2. 直接错误与指向

`dsh-client-modules` 的 require 解析顺序是：
**platform seed word → materialized module → registered package factory**，
三者全 miss 时抛上面这条错。也就是说：
`@deepseek-ai/dsh-client-product-analytics/remote` 这个 specifier 在打包时**没有被
物化进 client-modules 模块表**（build-time externals drift），运行时自然找不到。

引用方：`@deepseek-ai/dsh-api-remotes`（Node 侧引擎插件 + 浏览器侧 client bundle
两侧都引用了它）。

## 3. 产物证据（时间戳不一致，违反全量重建军规）

被引用包的产物目录：

```
vendor/deepseek-harness/packages/client/product-analytics/
├── package.json        # exports["./remote"] → ./lib/typert.remote-client.js（入口声明存在）
└── lib/
    ├── index.js               6,578 B   10-03 13:45
    ├── typert.remote-client.js 9,032 B  10-03 13:45
    ├── typert.host.js         14,076 B  10-03 13:45
    ├── client.js              2,342 B   10-03 23:15   ← 与其余产物不同批次
    ├── client.js.map                    10-03 23:15
    ├── tsconfig.client.tsbuildinfo      10-03 23:16
    └── tsconfig.host.tsbuildinfo        10-03 23:16
```

- `lib/` 内存在**两个构建批次**的产物：13:45 一批（index/typert）与 23:15 一批
  （client.js + 两个 tsbuildinfo）。tsbuildinfo 显示 23:15 那次是 `tsc -b`
  增量构建，且**没有产出完整的 client bundle 产物**。
- `scripts/build-dist.sh` L24-27 的军规注释正是针对这种状态：

  > 与 harness 全量构建（pnpm run build:lib）产物不一致（client.js 667.81→655.44
  > …）…会内联陈旧依赖快照。**凡动 vendor 层必须先跑 build:lib 全量重建。**

- 打包批次时间线：
  - 10/3 13:45 产物批次 → 14:07-14:08 `build-dist.sh` 打包成 zip/app
  - 10/3 15:47 起，App 拉起的引擎读到这批 vendor，web UI 即报 60 插件未激活
  - 10/3 23:15 又一次局部构建叠加（未跑 build:lib 全量），问题未修复
- 注意：`dist/dsh-host-0.1.0-arm64.zip`（14:08 打包）与当前
  `mac-arm64/dsh-host-app` 的该包产物**内容一致**，回退 zip 无效；
  10/1 的 dmg 是旧代码（api-remotes 当时还不引用 product-analytics/remote），
  可作应急回退但会丢功能。

## 4. 已排除项（节省排查时间）

1. **relay 插件（dsh-remote-relay-plugin / dsh-remote-relay-client）没有问题**：
   两者装在 profile 层 `~/.dsh/profiles/web/node_modules/`，文件完好
   （dist-local tgz 2026-10-02 打包）。它们挂不上是因为宿主 `remote.*` 服务全灭。
2. **引擎反复重启（每 60s crash loop）是另一个独立问题**：沙箱操作在
   `~/.dsh/.credentials.yaml.lock` 留下的 stale 接管记录（`.takeover-*` 文件）
   导致 `dsh-client-connection` 抢锁超时。已通过改写锁记录绕过，与本次 vendor
   缺陷无关。
3. **上游接口本身存在**：`product-analytics/package.json` 的 exports 声明了
   `./remote` 且指向的 `typert.remote-client.js` 文件在盘上——问题不在「文件缺失」，
   而在「**构建期没有把这个 specifier 物化进 client-modules 模块表**」。

## 5. 请开发确认的两点

1. **军规执行**：`build:lib` 全量重建后重新 build-dist 打包，问题是否随之消失
   （预期如此——当前 lib 处于跨批次不一致状态）。
2. **物化清单的鲁棒性**：若全量重建后 `product-analytics/remote` 仍 missed，
   则是 client-modules 的物化清单生成逻辑没有覆盖这个**新增的动态依赖**
   （api-remotes → product-analytics/remote 是较新引入的引用）——需要检查
   web-app/api-remotes 的 client bundle 构建配置（externals/materialize 清单）
   是否由依赖扫描自动生成，还是手工维护清单漏了它。

## 6. 建议的修复步骤（host-app 侧）

```bash
# 1) 全量重建 vendor（军规）
cd <host-app>/vendor/deepseek-harness
pnpm run build:lib

# 2) 重新打包
cd <host-app>
scripts/build-dist.sh

# 3) 重启 dsh-host-app，验证：
#    - web UI 不再报 "Failed to load plugins"
#    - curl -s http://127.0.0.1:3080/dsh-remote/session 返回配对卡 JSON
#    - POST /api/session/list 正常返回会话列表
```

## 7. 诊断命令（现场复核用）

```bash
# web UI 错误页原文
curl -s http://127.0.0.1:3080/ | grep -A3 "Failed to load plugins"

# 产物批次混用证据
ls -la <app>/Contents/Resources/engine/vendor/deepseek-harness/packages/client/product-analytics/lib/

# 控制面探针
curl -s  http://127.0.0.1:3080/dsh-host/healthz          # 200（插件层活着）
curl -s  http://127.0.0.1:3080/dsh-remote/session           # 404（配对路由灭）
curl -sX POST http://127.0.0.1:3080/api/session/list \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"t","method":"session/list","payload":{"args":{"_request":{}}}}'
```
