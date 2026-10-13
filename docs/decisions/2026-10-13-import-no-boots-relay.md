# ADR：`import dist/index.js` 不再自启 relay

**版本**：—（2026-10-13 修正）　**状态**：已生效　**日期**：2026-10-13

> 来源：2026-10-13 排查 `npm run smoke:relay`「打完绿就不退出」时定位并修复。
> 原始决策过程不存在（此前这段行为没有任何文档记载），本文只记录修复前后的事实。

## 问题

`server/src/index.ts` 原本用环境变量守卫模块顶层的自启逻辑：

```ts
if (process.env.NODE_ENV !== 'test' && !process.env.VITEST) { /* loadConfig + listen */ }
```

这个守卫挡得住 vitest，**挡不住任何 import 本模块的工具**。于是 `server/smoke/
harness.mjs` 只为了拿一个 `buildServer`，就顺带 listen 了**默认端口 8080**——
启动了一台谁也不负责关的幽灵 relay。

症状极其隐蔽：

- 冒烟的 5 条断言**全部通过**，照常打印 `[smoke:relay] OK`；
- 然后进程**永不退出**，只能 Ctrl-C（用户侧的观感是「跑着跑着就没声了」）；
- 端口 8080 留下一台没人认领的 relay。

三件事同时成立，所以每一件单独看都像正常现象。是**日志里出现两行
`relay_started_in_wss_mode`** 才暴露的：harness 自己那台听的是随机端口，
多出来的那行才是幽灵。

## 做法

守卫从「调用方要记得配的环境变量」改成「Node 自己的事实——本模块是不是进程入口」：

```ts
const isProcessEntry = process.argv[1]
  ? import.meta.url === pathToFileURL(process.argv[1]).href
  : false;
```

`loadConfig()` / `assertProductionConfig()` / `listen()` 全部收进这个条件里。

环境变量守卫**保留**（`NODE_ENV` / `VITEST`）没删——它是既有行为，去掉会改变
「以 `NODE_ENV=test` 跑 `dist/index.js` 时不启动」这个语义，没必要顺手改。

## 为什么用入口判定而不是环境变量

环境变量是**约定**：调用方得记得配，忘了就静默出错，而且没有任何机制告诉
import 方「你踩到我副作用了」。入口判定是**事实**：Node 自己知道，于是不存在
「忘了配」这种可能。以后任何 import `dist/index.js` 的一次性诊断脚本都自动安全。

## 不受影响的行为

所有**直接执行**的启动方式照旧自启，逐一验过：

| 启动方式 | 自启 | 验证处 |
|---|---|---|
| `node dist/index.js`（Dockerfile CMD / `npm start`） | ✅ | `scripts/e2e-stub.sh`（CI 真起真连 `/health`） |
| Dart 集成测试台 spawn `node server/dist/index.js` | ✅ | 同上 |
| `import { buildServer } from '../src/index.js'`（vitest） | ❌ 不自启 | `server/tests/relay.spec.ts` |
| `import { buildServer } from '../dist/index.js'`（smoke harness） | ❌ 不自启 | `server/tests/boot-side-effect.spec.ts` |

## 守门

`server/tests/boot-side-effect.spec.ts`：spawn 一个只做 `await import('./dist/index.js')`
的子进程，断言它**自己能退出**，且**它自己挑的端口没人听**。

两个设计细节不是洁癖，是被现实打出来的：

- **端口必须动态挑**（`listen({port:0})` 借一个再还）。写死端口会被**上一次跑失败
  留下的残留进程**误判成红——排查过程中真被这个坑过一次：第一次验证回退时留下的
  幽灵 relay 一直占着 18999，导致后面两次跑出的红都是「端口被占」，而不是真正的原因。
- **子进程必须无条件清理**（`afterEach` + `process.once('exit')`）。测试自己不能犯
  本文件要防的毛病：断言被外部中止后留下幽灵 relay。改这条守门时，第一版就是
  因为 vitest 5s 超时先于我的 10s 定时器，把子进程留成了孤儿。

## 附带效果

`smoke/harness.mjs` 现在不再需要靠 npm scripts 预设 `RELAY_PSK` /
`RELAY_PUBLIC_HOST` 才能 import（它本来就是显式传参给 `buildServer` 的）。
预设值保留着，免得有人改成直接跑时撞上 `assertProductionConfig`。

参见 [2026-08-30-relay-public-hardening](2026-08-30-relay-public-hardening.md)
里关于「模块顶层断言」的那条副作用说明。