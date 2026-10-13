/**
 * 守门：`import dist/index.js` 绝不能自启 relay。
 *
 * 这条 bug 的症状特别隐蔽——脚本自己的断言**全绿**、照常打印 OK，然后进程
 * 永不退出：`smoke/harness.mjs` import `buildServer` 时顺带 listen 了默认端口
 * 8080，那台幽灵 relay 没人负责关，事件循环被永久占住。手工跑冒烟的人只会
 * 以为「今天机器有点慢」。
 *
 * 所以断言不查日志、不看返回值，只查两件可观测的事实：
 *   1. 子进程自己**退得掉**（旧行为是永远不退出 → 超时判红）；
 *   2. 它自己挑的那个端口**没人听**（旧行为是有一台幽灵 relay 守着 → 连得上判红）。
 *
 * 「直接 `node dist/index.js` 仍要自启」那一半不在这儿重复验：CI 的
 * `scripts/e2e-stub.sh` 就是 spawn 真 `dist/index.js` 并断言 `/health` 200，
 * Dart 集成测试台也 spawn 它 —— 真起真连，比这里 spawn 后只看退出码更硬。
 */
import { describe, it, expect, afterEach } from 'vitest';
import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync } from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SERVER_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIST_ENTRY = path.join(SERVER_ROOT, 'dist/index.js');

/** 本次跑出来的子进程，无论断言成败都必须清掉。 */
const spawned = new Set<ChildProcess>();
afterEach(() => {
  for (const child of spawned) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
  spawned.clear();
});
// 测试被外部中止（vitest 超时、Ctrl-C）时 afterEach 未必跑得到，而残留的
// 幽灵 relay 会一直占着端口——正是本文件要防的那件事，测试自己不能犯。
process.once('exit', () => {
  for (const child of spawned) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
});

/** 向系统借一个当前空闲的端口，跑完即还。写死端口会被无关残留进程误判成红。 */
function pickFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen({ port: 0, host: '127.0.0.1' }, () => {
      const { port } = srv.address() as net.AddressInfo;
      srv.close(() => resolve(port));
    });
  });
}

function canConnect(port: number, timeoutMs = 800): Promise<boolean> {
  return new Promise((resolve) => {
    const sock = net.connect({ port, host: '127.0.0.1' });
    const done = (result: boolean) => {
      sock.destroy();
      resolve(result);
    };
    sock.setTimeout(timeoutMs);
    sock.once('connect', () => done(true));
    sock.once('error', () => done(false));
    sock.once('timeout', () => done(false));
  });
}

async function importEntry(port: number): Promise<{
  code: number | null; stdout: string; stderr: string; timedOut: boolean;
}> {
  const child = spawn(
    process.execPath,
    ['--input-type=module', '-e', "await import('./dist/index.js'); console.log('IMPORT_DONE')"],
    {
      cwd: SERVER_ROOT,
      env: {
        ...process.env,
        PORT: String(port),
        // 给一个既不是文档默认值也不是空值的 PSK / publicHost：这两个变量是给
        // 「直接启动」那条路的断言用的，import 路线不该被它们拦下、也不该靠它们
        // 侥幸过关 —— 红灯只可能来自「它不该自启」这一件事。
        //
        // 值必须**短于 24 字符**：scripts/scan-secrets.sh 的规则 4 按长度把
        // 「测试 fixture / 裸标识符」和「真凭据」分开（本仓 PSK 是
        // `openssl rand -hex 32`，64 个 hex）。写成更长的「更真实」的值不会让
        // 这条守门更强，只会让脱敏扫描变红。
        RELAY_PSK: 'boot-effect-not-secret',
        RELAY_PUBLIC_HOST: 'relay.example.com',
        // 父进程是 vitest（带 VITEST / NODE_ENV=test）。必须摘掉，否则旧代码那
        // 两个守卫恰好会把自启挡掉，这条用例就成了永远绿的废品。
        VITEST: undefined,
        NODE_ENV: undefined,
      } as NodeJS.ProcessEnv,
    },
  );
  spawned.add(child);

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => { stdout += d.toString(); });
  child.stderr.on('data', (d) => { stderr += d.toString(); });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, 10_000);

  return new Promise((resolve, reject) => {
    child.on('error', (err) => { clearTimeout(timer); reject(err); });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut });
    });
  });
}

describe('启动副作用：import 不得自启 relay', () => {
  // 超时给到 15s：子进程 10s 才被判死，这样红的是本文件那句「它不该自启」的
  // 断言（带 stdout/stderr），而不是 vitest 自己的 5s 超时——后者只说「超时了」，
  // 看不出该怪谁。红的必须能自解释，否则下次没人查。
  it('import dist/index.js 后进程自行退出，且不留下监听', { timeout: 15_000 }, async () => {
    if (!existsSync(DIST_ENTRY)) {
      // 本仓纪律：前提不满足就打印原因并跳过，不让「没 build」伪装成绿灯。
      console.warn(`skip: ${DIST_ENTRY} 不存在，先跑 \`pnpm build\`（CI 与 verify.sh 都是先 build 再 test）`);
      return;
    }

    const port = await pickFreePort();
    const result = await importEntry(port);

    expect(
      result.timedOut,
      `import 后 10s 仍未退出 —— dist/index.js 仍在 import 时自启 relay。\n` +
      `stdout: ${result.stdout}\nstderr: ${result.stderr}`,
    ).toBe(false);
    expect(result.code, `import 应正常退出。stderr: ${result.stderr}`).toBe(0);
    expect(result.stdout).toContain('IMPORT_DONE');

    expect(
      await canConnect(port),
      `端口 ${port} 上还有人监听 —— 自启出来的幽灵 relay 没被关掉。`,
    ).toBe(false);
  });
});