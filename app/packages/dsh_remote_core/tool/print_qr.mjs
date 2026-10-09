// Print a terminal QR for a pairing URL — the no-USB path to verify the
// app's CAMERA scan end-to-end (plan §12 相机路径取舍：扫码自动化不划算，
// 但可以零摩擦人工验：终端出码 → 手机扫）。
// Usage: node print_qr.mjs "<url>"
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const repoRoot = process.env.DSH_REPO_ROOT ??
  path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
const require = createRequire(`${repoRoot}/client/package.json`);
const qrcode = require('qrcode-generator');

const url = process.argv[2] ?? process.env.DSH_PAIRING_URL;
if (!url) {
  console.error('usage: node print_qr.mjs "<pairing-url>"');
  process.exit(2);
}
const qr = qrcode(0, 'M');
qr.addData(url);
qr.make();
const n = qr.getModuleCount();
const quiet = 2;
const lines = [];
for (let r = 0; r < n + quiet * 2; r++) {
  let line = '';
  for (let c = 0; c < n + quiet * 2; c++) {
    const dark = r >= quiet && c >= quiet && r < n + quiet && c < n + quiet &&
      qr.isDark(r - quiet, c - quiet);
    line += dark ? '██' : '  ';
  }
  lines.push(line);
}
console.log(lines.join('\n'));
console.log('\n' + url + '\n');
