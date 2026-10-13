# 排障手册：插件在 DSH 里报「异常」/ 装不进 profile / 重启后不生效

> 实战记录，2026-10-04。宿主 DSH `0.2.0-rc.2` 升级时踩出来的三个坑，
> 每一个都曾让"看起来成功"的安装其实没生效。
>
> **一句话总纲**：`pnpm install` 退出码为 0 **不等于**新代码在跑。
> 判据只有一个——看**磁盘上实际存在的文件**和**引擎探针的响应**。

## 0. 先分清三种"失败"

| 现象 | 性质 | 判据 |
|---|---|---|
| install 报 `ERR_*` 并非 0 退出 | 真失败 | 退出码 |
| install 退出 0，但重启后行为没变 | **假成功**（本文重点） | 见 §2、§3、§4.1 |
| 满屏 `missing peer` 警告 + 退出 0 | **正常噪音**，不是失败 | 见 §5 |

## 1. 坑一：peer 范围没跟上宿主版本 → 插件管理器判「异常」

**报错原文**

```
dsh-remote-relay-plugin@0.1.0 与 DSH 0.2.0-rc.2 不兼容
（要求 @deepseek-ai/dsh-host-webserver ^0.1.7-rc.2），
运行它可能导致崩溃或数据丢失。请卸载后重新安装与当前 DSH 兼容的版本。
```

**根因**：`plugin/package.json` 的 `peerDependencies` 写死 `^0.1.7-rc.2`，
而宿主（App 内嵌的 vendor DSH）已升到 `0.2.0-rc.2`。

semver 上 `^0.1.7-rc.2` 等于 `>=0.1.7-rc.2 <0.2.0`。**且带 prerelease 的版本
只有命中"同三元组且带 prerelease"的比较器才算匹配**——这里没有
`[0,2,0]` 带 prerelease 的比较器，所以 `0.2.0-rc.2` 判为不满足。

**修法**：`plugin/package.json` 里 peer + dev 共 8 处 `^0.1.7-rc.2` → `^0.2.0-rc.2`。

> ⚠️ **报错里"卸载后重新安装"是误导**。重装**同一个版本**的包毫无用处——
> 它声明的还是同一个范围，检查还会挂。必须改声明。

**注意宿主的真实位置**：profile 里**没有**装 `dsh-host-webserver`，
跑的是 App 内置的那份。查版本要去 App 的 vendor 树里查：

```bash
node -e "console.log(require('<host-app>/vendor/deepseek-harness/packages/host/webserver/package.json').version)"
```

### 「不包含任何组件」不是第二个故障

插件详情里"包含的组件"为空，是**按组件清单口径**统计的结果。本插件的设置卡片
通过 `dsh.client.inject` 注入 + `cordis.patch.yml` 提供，不走组件清单，显示为空属正常。

## 2. 坑二（最阴）：版本号不变 → pnpm 判定 up to date → **装了个旧的**

**这是本文最值得记住的一条。**

本地 `file:` 安装（`install-into-profile.sh` 走的就是这条）靠 lockfile 里的
**integrity 哈希**识别 tarball 变化。**只要 tarball 名字里的版本号没变**，
哪怕内容、依赖声明全改了，pnpm 也会判定 `Already up to date`、**根本不解压**。

**现场**：

```
==> pnpm install in ~/.dsh/profiles/web
Already up to date
Progress: resolved 20, reused 2, downloaded 0, added 0, done
Done in 261ms                          ← 快得可疑
installed into profile: web            ← 退出 0，装了个旧的

$ ls -ld ~/.dsh/profiles/web/node_modules/dsh-remote-relay-plugin
drwxr-xr-x ... Oct  2 16:58           ← 还是两天前的目录
$ node -e "console.log(require('.../package.json').peerDependencies)"
{ ... "@deepseek-ai/dsh-host-webserver": "^0.1.7-rc.2" }   ← 旧的！
```

**军规：改完插件代码/声明重新安装前，先 `plugin/package.json` 里的
`version` 升一位。** 本次 `0.1.0` → `0.1.1` 后才真正重装：

```bash
# 确认真的换了
ls -ld ~/.dsh/profiles/web/node_modules/dsh-remote-relay-plugin   # 时间戳应是刚才
node -e "const p=require('.../dsh-remote-relay-plugin/package.json');
         console.log(p.version, p.peerDependencies['@deepseek-ai/dsh-host-webserver'])"
```

> `Done in 261ms` / `resolved 20, reused 2` 这类**极快完成 + 0 downloaded**
> 组合，就是"它压根没干活"的指纹。看到就先去查磁盘，别急着重启 App。

## 3. 坑三：profile 装不上，卡在别人家的包

```
ERR_PNPM_WORKSPACE_PKG_NOT_FOUND
  In : "@deepseek-ai/schemastery@workspace:~" is in the dependencies
       but no package named "@deepseek-ai/schemastery" is present in the workspace
This error happened while installing the dependencies of
  @deepseek-ai/dsh-tool-ask-user@0.2.0-rc.2
```

**根因**：profile 目录里有 `pnpm-workspace.yaml`（`packages: [.]`），
pnpm 把 profile 当 workspace 根。`file:` 指向的是**裸源码目录**，pnpm 不会
对它 `pack`，所以包 manifest 里的 `workspace:` 协议**不会被重写**，
profile 这个独立 workspace 自然解析不出来。

同一个 profile 里 9 个 `file:` 依赖，只有 host-app 的 2 个包
（`interaction/tool-ask-user`、`interaction/user-questions`）中招——
只有它们的 `dependencies`（真实依赖）用了 `workspace:`
（其余 7 个干净，peer 不算，所以之前一直没炸）。

**归属**：**host-app 侧的问题**，不是本仓。修法二选一：

- vendor 仓里把 `dependencies` 的 `workspace:~` 改成 `^3.18.4`（同文件其他处
  已这么写，最省事）；**或**
- profile 改吃 `.tgz`（`pnpm pack` 时会把 `workspace:` 重写成真实版本）。

> `install-into-profile.sh` 有备份+自动回滚，这类失败不会留下脏状态。
> 但**排查时别停在"install 失败"**——往上翻一层，往往是依赖树里别人的包坏了。

## 4. 排障顺序（照着走，别跳）

```bash
# 0. 宿主版本（决定 peer 范围该写什么）——注意在 App 的 vendor 树里查
node -e "console.log(require('<host-app>/vendor/deepseek-harness/packages/host/webserver/package.json').version)"

# 1. 声明对不对
grep -n 'dsh-host-webserver' plugin/package.json

# 2. 版本号升了没（坑二：不升 = 白装）
node -e "console.log(require('./plugin/package.json').version)"

# 3. 验证 + 重打包
pnpm -r typecheck && pnpm -r test
bash scripts/pack-local.sh

# 4. 解包核验 tarball 里的声明（别只信 build 输出）
tar -xzf dist-local/dsh-remote-relay-plugin-*.tgz -O package/package.json \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).peerDependencies))"

# 5. 装 profile（必须在非沙箱终端跑，见 §6）

# 6. 核验磁盘实体——这才是判据
node -e "const p=require(process.env.HOME+'/.dsh/profiles/web/node_modules/dsh-remote-relay-plugin/package.json');
         console.log(p.version, p.peerDependencies)"

# 7. 这一层被登记了吗（文件在盘上 ≠ 宿主会加载，见 §4.1）
node -e "const p=require(process.env.HOME+'/.dsh/profiles/web/package.json');
         console.log((p.dsh?.profile?.bundles ?? []).includes('dsh-remote-relay-plugin'))"

# 8. 重启 App 后，跑引擎探针（端到端证据）
curl -s http://127.0.0.1:3080/dsh-host/healthz
curl -s http://127.0.0.1:3080/dsh-remote/session
```

### 4.1 第 7 步打印 `false`：装了，但没成为一层

包在 `dependencies` 里只代表 pnpm 把文件放到了盘上。dsh 要把它提升成 profile 的一个
**层**（宿主真正会加载的东西），还需要包名出现在 `dsh.profile.bundles` 里。

- 走 `dsh plugin add` 时，这一步由 **dsh 自己的插件管理器**对账（它就是执行安装的那一方）；
- 走 `scripts/install-into-profile.sh` / `scripts/dev-test-profile.sh` 时由脚本自己做——
  它们直连 pnpm，不经过 dsh 的安装路径。

漏掉它的症状正是最难查的那种：**安装报成功，插件就是不加载**。补法是把包名加进
`dsh.profile.bundles` 数组，再 `pnpm install`。

### 探针怎么读

```jsonc
// GET /dsh-remote/session —— 200 且有内容 = 插件真加载了 + 隧道通了
{
  "tunnel": { "state": "connected", "relayUrl": "https://...", "manualOff": false },
  "active":  { "sessionId": "sess_...", "qrUrl": "https://...?..." }
}
```

对比 `docs/internal/vendor-build-defect-report-20261004.md` 里那次 404 的故障态：
**同一个路由返回 200 且 `tunnel.state: connected`**，是"宿主控制面活着 + 插件加载成功"
的最强证据——比退出码、比文件时间戳都可靠。

## 5. `missing peer` 警告是噪音，不是失败

profile 的 `pnpm-workspace.yaml` 里有 `autoInstallPeers: false`——peer 由宿主 App
的 vendor 提供，profile 故意不装。所以**每个包**都会报一堆 missing peer，
host-app 的包也一样，刷屏属正常。

**判据只看**：`ERR_*` 有没有出现、退出码是不是 0、`installed into profile` 有没有打印。

## 6. 执行环境分工（agent 必读）

本仓的安装类操作有**硬性环境限制**，别在受限 shell 里反复重试：

| 操作 | 受限 shell（agent 沙箱） | 说明 |
|---|---|---|
| `pnpm install`（仓内） | ❌ | 需要 `~/.npm` 与 store 的 rename 权限 |
| `bash scripts/pack-local.sh` | ✅ | 全在 workspace 内 |
| `pnpm -r typecheck` / `test` | ✅ | 全在 workspace 内 |
| `scripts/install-into-profile.sh` | ❌ | 写 `~/.dsh`（workspace 外） |

受限 shell 里 `pnpm install` 的典型报错：`EPERM`（下载临时文件 rename 不进 store）。
可行的部分绕法是 `--store-dir .pnpm-store`（store 挪进仓内），但**不代表整体能装完**。

**结论：装依赖和装 profile 一律请用户在普通终端跑**，agent 只做校验、构建、打包。
另见 `.gitignore` 里 `.dsh-e2e/` 与 `.pnpm-store/` 的注释——同一类坑的已有记录。

## 7. 遗留观察（下次升 DSH 时会再冒出来）

- `@deepseek-ai/dsh-client-ui-reference` 在 profile 里仍钉在 `0.1.0-rc.8` 全套 peer。
  宿主已 `0.2.0-rc.2`，**它会成为下一个报「异常」的包**。需 host-app 侧一并升级。
- 本仓 `app/README.md` 里"tested against dsh `0.1.7-rc.2`"是 E2E 实测记录，
  宿主升级后应重跑 app 的 E2E 再更新，别只改数字。
- 宿主每次大版本升级，本仓 `plugin/package.json` 的 8 处 `^0.2.0-rc.2` 都要跟着走一遍
  （peer + dev 两组，`grep -c 'deepseek-ai/dsh-' plugin/package.json` 可自查）。
