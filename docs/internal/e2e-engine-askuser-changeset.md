# 屏 P 验证：引擎 ask-user 工具挂载变更清单

生成时间：2026-10-03 11:25
目的：为 App 屏 P（审批/提问卡）真机往返验证，给引擎装上 `ask_user_question` 工具
状态：**已离线验证（dsh --profile web --dump-config 确认工具在组合树内），等待引擎重启生效**

---

## 一、为什么需要改引擎

App 屏 P 的协议/UI/自动化测试都齐了，但真机上从没出现过一张真实审批/提问卡。
排查结论（证据链）：

1. `dsh: skipping profile bundle "@deepseek-ai/dsh-tool-ask-user": declares no dsh.bundle`（引擎启动日志）
2. 引擎 profile 的 `pluginInventory` 共 197 个 entry，`tool-ask-user` 注册数 = **0**
3. 引擎 profile 的 bundles 列表原本不含该包；`user-questions`/`approval` 能力层已 enabled
4. → 断点在**引擎侧最上游**：模型手里没有"问人"的工具，waterfall 无从发起
   → **不是 relay 插件转发问题**（$events 通道已真机验证可收帧）

---

## 二、改动清单（全部在引擎 profile 副本内，vendor 源码仓未动）

profile 根：`~/.dsh/profiles/web/`

| # | 文件 | 改动 | 备份 |
|---|------|------|------|
| 1 | `package.json` | `dependencies` 增加 `@deepseek-ai/dsh-tool-ask-user`、`@deepseek-ai/dsh-user-questions`（file: 指向 vendor 源码） | `package.json.bak-askuser-0955` |
| 2 | `node_modules/@deepseek-ai/dsh-tool-ask-user/` | 新增（vendor 源码副本 + `dsh.bundle` 声明 + `cordis.patch.yml`） | — |
| 3 | `node_modules/@deepseek-ai/dsh-user-questions/` | 新增（vendor 源码副本，供 peer import） | — |
| 4 | `node_modules/@deepseek-ai/dsh-sys-schedule/cordis.patch.yml` | 末尾追加 `insert: tool-ask-user`（实际挂载点） | `cordis.patch.yml.bak-askuser` |

**挂载方式说明**：最终采用「挂进已加载 bundle 的 cordis patch」而非「加进 bundles 列表」。
原因：bundles 机制要求包同时具备 `dsh.bundle` 元数据 + `cordis.patch.yml` + pnpm 状态一致
（lock/store），沙箱无法完成 `pnpm install`（EPERM），故改走已验证可用的 patch 叠加路径。

**vendor 源码仓（host-app）零改动** —— 改动全在 `~/.dsh` 的 profile 副本里。

---

## 三、重启后验证清单

1. `pluginInventory/list` → `tool-ask-user` 应 enabled=true
2. 手机 App 应自动过闸恢复配对（引擎重启会清 pairing 状态）
3. 发 prompt 逼模型调 `ask_user_question`（例：「执行前先向我提问确认」）
4. 手机应渲染提问卡（屏 P）→ 作答 → 引擎拿答案继续 → 闭环成立

---

## 四、回滚（验证完如需撤销行为变化）

```bash
cd ~/.dsh/profiles/web
# 1. 还原 patch
cp node_modules/@deepseek-ai/dsh-sys-schedule/cordis.patch.yml.bak-askuser \
   node_modules/@deepseek-ai/dsh-sys-schedule/cordis.patch.yml
# 2. 还原 package.json
cp package.json.bak-askuser-0955 package.json
# 3.（可选）移除两个包副本
#    node_modules/@deepseek-ai/dsh-{tool-ask-user,user-questions}/
# 4. 重启引擎
```

`--dump-config` 可在重启前离线确认 patch 生效；`dsh plugin --profile web install` 不需要执行
（会与运行中引擎的 package.json.lock 接管锁冲突，报 EPERM，属预期）。

---

## 五、已知遗留（不影响本次验证）

- `~/.dsh-host/dsh-home/profiles/web/node_modules/@deepseek-ai/dsh-{tool-ask-user,user-questions}`
  —— 第一次装错 profile 时留下的副本；该 profile 非活跃实例，删不删都不影响。
- profile 层 `cordis.patch.yml` 引用了不存在的 entry `host-app-remote`（历史遗留 warning，与本次无关）
- 3080 端口有两个引擎监听：dsh-host-app app 引擎（127.0.0.1，手机隧道连它）+ 老进程 PID 52819（*:3080，cwd 在 relay 仓，来历不明）
