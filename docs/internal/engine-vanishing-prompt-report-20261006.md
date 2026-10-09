# 引擎交接报告：`session/prompt` 偶发「已接受但从未落库」的消息丢失

- 日期：2026-10-06 23:24–23:28
- 报告方：dsh-remote-relay（App 侧）
- 现象来源：用户报告「在 App 上发送好几次消息，dsh 那边都没有收到」；App 侧定位复现如下

## 1. 现象

`session/prompt` 返回 `{ok: true, value: {accepted: true}}`，但该消息**从未出现在任何会话 journal 中**，
对应的模型回合也没有启动。同一条发送路径（同一 App、同一会话、相隔 4 分钟）再发一次即正常落库。

## 2. 实测证据链

| 时刻 | 动作 | prompt 结果 | 是否落 journal |
|---|---|---|---|
| 23:24:25 | App 内 composer 发送 `delivery-test-01`（logcat: `[e2e] prompt ok=true err=null`） | `accepted: true` | ❌ 全盘 100+ 会话 journal 搜索：**无记录** |
| 23:26:38 | Mac 直连引擎，同 wire 形状（`mode: queue` + `requestId` + `clientTimeZone`）`repro-app-style-1` | `accepted: true` | ✅ `session-ea98de4a` seq 132-135 完整落库并回复 |
| 23:28:39 | App 内同路径发送 `，delivery-test-02` | `accepted: true` | ✅ `session-ea98de4a` seq 140 落库、seq 137-143 回合完整处理并回复 |

即 3 次发送、1 次消失；消失与不消失的**请求形状无差异**（同 `mode`/同字段），只差时间。

## 3. 与用户「发好几次都没收到」的关系

用户 21:50 左右报告的问题与上表同型：消息发出后 App 侧拿不到成功态之外的任何痕迹、引擎侧无记录、
回合未启动。本次会话 journal 里用户真实消息（21:06 港股提问、22:21 「你好」「后续持仓怎么操作」）
**都在且都有回复**——说明丢失是**概率性**的，不是该会话专属故障。

## 4. 请求路径（App → 中继 → 引擎）

```
App composer → ChatController.send
  → POST /api/session/prompt  args.request{sessionId, mode: 'queue', requestId, clientTimeZone, content[]}
  → <relay-host>（WSS → 本地 mux 桥）
  → engine: session-controller
     ├─ accepted: true  ← 引擎已应答
     └─ ✗ 期望：user/message 事件落 journal、turn/start
```

应答与落库之间存在一个断点：引擎回了 `accepted`，但未产生任何持久事件。
从 App 视角无法区分「引擎已接受并丢弃」与「引擎已接受、落库事件在流里丢了」——两种情况下
wire 表现完全一样（`ok=true` 后无后续帧）。

## 5. 建议排查方向（引擎/中继侧）

1. `session/prompt` 的 `queue` 模式在**空闲 agent** 上的入队路径：入队与 splice 之间是否可能
   丢 pending 项（注意 journal 里出现过 `agent/inbox/spliced {target:'next-turn', start:0, removedCount:1, inserted:[]}`
   这种「移除 1 条、插入 0 条」的可疑帧，与本现象时间线一致）。
2. 中继 mux 桥对 `session/prompt` 响应的时序：若应答先于请求体完整落库到达，App 侧无法感知后续失败。
3. 若引擎侧无法复现：加一条**端到端探针**——`prompt` 应答里回显 requestId，并要求调用方在
   N 秒内于 `session/follow` 快照中看到自己的 message，否则客户端可自动重试（幂等 requestId 已具备）。

## 6. 用户侧临时对策

发出后若几秒内 App 未出现自己的消息气泡，直接重发即可（requestId 每次新生成，重发不产生重复）。
本报告不含 App 侧缺陷：发送链路、往返确认、流式帧（本次同会话 491 帧全达）、落库全部验证通过。
