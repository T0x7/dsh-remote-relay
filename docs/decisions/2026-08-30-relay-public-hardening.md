# ADR：relay 公网暴露的安全基线

**版本**：—（v3.28 前后确立）　**状态**：已生效　**日期**：2026-08-30

> 来源：从 `server/src/config.ts:10-115`（`assertProductionConfig` 与
> `isValidAuthority`）与 `server/src/store.ts:5-16` 的注释回填。
> 原始决策文档未随代码保存；本文只记录当前代码仍在执行的三道闸。

## 背景

这个项目的前提就是「把本机绑定的 dsh 引擎安全地暴露到公网」，所以安全基线不是
加分项而是前提。代码里有三道互相独立的闸。

## 三道闸

### ① PSK 不许用文档里的默认值

`config.ts` 定义了 `DEFAULT_INSECURE_PSK = 'dsh-remote-relay-default-insecure-psk'`，
它只用于「没配也能跑起来」的便利，但**生产启动会拒绝它**：

```
RELAY_PSK is unset or the documented insecure default —
set a strong random value (openssl rand -hex 32)
```

### ② `RELAY_PUBLIC_HOST` 必填且必须是规范 authority

这是**最容易被低估**的一条：不设它，proxy 会把请求以 `Host: 127.0.0.1:3080`
呈现给 dsh —— 也就是**以 loopback 身份**，从而**在远端解锁 16 个 PRIVILEGED 方法**。

`isValidAuthority` 要求它是裸 authority（host 或 host:port），与 dsh 的
`--trusted-host` 对齐。

> 这条在冒烟测试里踩过：把 publicHost 设成 `127.0.0.1` 会触发
> `/auth not applicable to loopback` 的 504 —— relay 侧有对应的 loopback 保护。
> 冒烟用的 publicHost 必须是**非 loopback** 的域名，且落在引擎 trusted-host 里。

### ③ `assertProductionConfig` 在启动路径上

注释明说：「测试与 dev server 直接构造 SessionManager / buildServer 并传显式值，
不走这里」——所以它拦的是**生产启动**，不是单测。

⚠️ 副作用：`loadConfig()` + `assertProductionConfig()` 在 `index.ts` 模块顶层执行，
所以**直接 `node dist/index.js` 启动**必须提供这两个变量（import 不触发——见
[2026-10-13-import-no-boots-relay](2026-10-13-import-no-boots-relay.md)）。
`server/smoke/harness.mjs` 因为是 import + 显式传参，本身不依赖它们，但 npm scripts
里仍预设了本地值，免得有人改成直接跑时撞上这条断言。

## 落盘状态按密钥对待

`store.ts` 的 `StoredSession` 里 `sessionSecrets` 是**静态凭据**，其所在卷
「必须像任何其他 secret store 一样对待」（注释直接引本文档）。

选型理由同处有记：WAL + `busy_timeout`，因为 watchdog 进程会读同卷的 audit DB，
两个 DB 都在 relay-data 卷上。