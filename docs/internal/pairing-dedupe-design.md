# 设计待办：配对去重——App 侧按 (mid, deviceId) 归并同一台机器

状态：**设计稿，未实施**（2026-10-10，源自真机事故：v3.177 修复后重配对产生第二张卡片）。

## 问题

App 侧机器条目的身份键是 `sessionId`（`pairing_flow.dart:54` `id: params.sessionId`）。
同一台物理机器一旦换发**新**会话（30 天到期重配、或历史缺陷的 lazy-mint 换发），
App 就长出第二张卡片，旧条目孤儿化（appId 还在倒计时一个已死的会话）。

链接里的 `mid`（机器绑定哈希，`computeMid(dataRootDir)`，同一台机器恒定）本可用于
归并，但目前只参与 URL 防伪验签，App 解析时弃之不用；卡片名字相同
（都来自链接 `name=` 参数即主机名）也不触发合并。

## 为什么不能只按 mid 去重

同一台机器**支持多设备各持一条配对**（手机 + 平板；v3.170 多配对共存；relay
设备列表的 `paired M` 计数即此）。`mid` 标识机器、标识不了配对设备——按 mid
替换会把第二台设备的卡片顶掉。正确的身份粒度是 **(机器, 配对设备)**。

## 方案（App 侧为主，client / relay 零改动）

1. **App 首启生成稳定 `pairingDeviceId`**（UUID，存 Keychain / Keystore）。
   卸载重装即视为新设备——语义自洽，无需服务端配合。
2. **`MachineEntry` 持久化 `mid`**：解析链接时 `params.mid` 现成有，落库即可
   （现版本没存——这是本方案唯一的 schema 增量）。
3. **配对确认前去重**：解析出新链接的 `(newSessionId, mid)` 后，遍历现有条目：
   - 存在 `entry.mid == mid` **且** `entry.pairingDeviceId == 本机 deviceId`
     → **替换**：覆盖 sessionId / 凭据 / pin 种子；`firstPairedMs` 是否保留需
     拍板（保留 = 30 天绝对钟不重置，到期仍强制重配）。
   - `mid` 相同但 `deviceId` 不同 → 新卡片（第二台设备的合法配对）。
   - 都不匹配 → 新卡片。
4. **逃生门**：长按「添加机器」提供"作为独立配对添加"（跳过去重），照顾
   同一手机管理同机器多 profile 的边缘用法。

## 为什么 relay / client 不用动

- `mid` 已在配对链接里，是现成信息；去重发生在 **App 本地**（App 只需要自己
  的历史条目 + 新链接，不需要 client 或 relay 参与归并）。
- 验签不受影响：hash 规范串是 `sessionId|exp|mid|t`，与 App 本地存不存 mid 无关。

## 验收

- 同机器重配对（30 天到期场景）→ 卡片数不变，凭据滚动，遥测不中断。
- 第二台设备扫同一台机器 → 出第二张卡，原卡不受影响。
- 卸载重装 App 再配对 → 视为新设备，出新卡（旧卡随旧配对过期自然失效）。
- 既有测试：`machines_list_refresh_test` / `pairing_flow` 相关全绿；新增去重
  分支测试三条（替换 / 新设备 / 逃生门）。

## 关联

- 2026-10-10 事故：v3.176 includes 缺陷（commit bd7be41b 修复）+ lazy-mint
  孤儿化手机配对——本设计消除"孤儿化卡片"这一残留症状。
