#!/bin/bash
# L2 · 桩上游端到端（CI 跑，无需真实引擎）
#
# 验证 relay + client + 隧道 + 配对的完整链路，但**上游是桩**：脚本自己起一个
# 返回固定 HTML 的假 SPA。所以它验的是「relay 自己通不通」，与引擎版本无关，
# 是最稳定的一层，任何提交都该过。
#
# 需要连真实 dsh 引擎的断言在 `server/smoke/` 下，分 relay 契约与引擎契约两册，
# 手动运行，不进 CI。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/dsh-relay-e2e2.XXXXXX)
OUT=$TMP/result.txt
PSK="e2e-stub-psk-$RANDOM"
cleanup() { pkill -P $$ 2>/dev/null; lsof -ti :8083 -ti :9998 2>/dev/null | xargs kill 2>/dev/null; }
trap cleanup EXIT

# Every failure path goes through here. The early exits used to append to $OUT
# and exit without printing it, so a red CI run showed "Process completed with
# exit code 1" and nothing else — indistinguishable from a script that never
# ran, which is why the one environment-specific failure below took a full
# diagnosis round to pin down instead of one log read.
fail() {
  echo "[e2e-stub] FAIL: $1" | tee -a "$OUT" >/dev/null
  cat "$OUT"
  # The services log into temp files this script otherwise never reads, so a
  # service that died at boot reported a blank line and nothing else. Any
  # failure here dumps them.
  for f in relay serve pair; do
    if [ -s "$TMP/$f.log" ]; then
      echo "[e2e-stub] --- $f.log (tail) ---"
      tail -20 "$TMP/$f.log"
    fi
  done
  exit 1
}

# upstream "SPA"
node -e 'require("http").createServer((q,s)=>{s.setHeader("content-type","text/html");s.end("<html>ok-spa-e2e</html>")}).listen(9998,"127.0.0.1")' >/dev/null 2>&1 &
# Poll for it the way the relay is polled below, instead of sleeping a fixed
# half second and probing once. On a cold CI runner node takes seconds to boot,
# and a single 3s probe after 0.5s loses that race — which is exactly what this
# step did before, only on machines slower than the developer's.
for i in $(seq 1 50); do curl -sf -m 2 http://127.0.0.1:9998/ | grep -q ok-spa-e2e && break; sleep 0.2; done
curl -sf -m 3 http://127.0.0.1:9998/ | grep -q ok-spa-e2e || fail "upstream dead"
echo "[e2e-stub] upstream up" >> $OUT

# relay server (exec so kill works)
cd $ROOT/server && HOST=127.0.0.1 PORT=8083 RELAY_PSK=$PSK RELAY_PUBLIC_HOST=127.0.0.1:8083 \
  DSH_UPSTREAM=http://127.0.0.1:9998 AUDIT_DB_PATH=$TMP/audit.db STATE_DB_PATH=$TMP/state.db \
  node dist/index.js >>$TMP/relay.log 2>&1 &
RELAY_PID=$!
for i in $(seq 1 50); do curl -sf -m 2 http://127.0.0.1:8083/health >/dev/null 2>&1 && break; sleep 0.2; done
HEALTH=$(curl -s -m 3 http://127.0.0.1:8083/health)
echo "[e2e-stub] relay /health: $HEALTH" >> $OUT
# A relay that never came up used to be reported as a blank /health line, and
# the next two steps then failed on a pairing that was never going to happen.
# Say so here instead, with the boot log attached.
[ -n "$HEALTH" ] || fail "relay never became healthy"

# client serve (holds tunnel)
cd $ROOT/client && DSH_REMOTE_RELAY_URL=http://127.0.0.1:8083 DSH_REMOTE_PSK=$PSK \
  DSH_BIND_PORT=9998 DSH_REMOTE_DATA_ROOT=$TMP/client node dist/cli.js serve >$TMP/serve.log 2>&1 &
SERVE_PID=$!
sleep 2
echo "[e2e-stub] serve: $(grep -o 'state=[a-z-]*' $TMP/serve.log | head -1)" >> $OUT

# pair (one-shot, exits by itself)
cd $ROOT/client && DSH_REMOTE_RELAY_URL=http://127.0.0.1:8083 DSH_REMOTE_PSK=$PSK \
  DSH_BIND_PORT=9998 DSH_REMOTE_DATA_ROOT=$TMP/client timeout 20 node dist/cli.js pair >$TMP/pair.log 2>&1
QR_URL=$(grep -E '^http://127\.0\.0\.1:8083/\?sessionId=' $TMP/pair.log | head -1)
echo "[e2e-stub] pair sessionId: $(grep -o 'sess_[0-9a-f]*' $TMP/pair.log | head -1)" >> $OUT
echo "[e2e-stub] QR rendered in terminal: $(grep -c '█' $TMP/pair.log) block chars" >> $OUT
if [ -z "$QR_URL" ]; then
  echo "[e2e-stub] pair.log head:" | tee -a "$OUT" >/dev/null
  head -5 "$TMP/pair.log" | tee -a "$OUT" >/dev/null
  fail "no QR URL"
fi

sleep 3.5   # serve 的配对收养轮询（2s）把 pair 进程铸的配对经活隧道补注册
CODE=$(curl -s -L -m 15 -o $TMP/scan.html -w '%{http_code}' "$QR_URL")
echo "[e2e-stub] GET qrUrl → $CODE, SPA bytes via data plane: $(grep -q ok-spa-e2e $TMP/scan.html && echo yes || echo NO)" >> $OUT

ANON=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8083/)
echo "[e2e-stub] GET / anonymous → $ANON (expect 401/403)" >> $OUT

kill $RELAY_PID $SERVE_PID 2>/dev/null

# 判定 + 把结果打到 stdout：跑完看不见输出的话，这个脚本在本地排查时等于没用。
if grep -q "FAIL" "$OUT"; then
  echo "[e2e-stub] FAILED"; cat "$OUT"; exit 1
fi
if ! grep -q "SPA bytes via data plane: yes" "$OUT"; then
  echo "[e2e-stub] FAILED — SPA 未透过数据面"; cat "$OUT"; exit 1
fi
if ! grep -qE "GET / anonymous → (401|403)" "$OUT"; then
  echo "[e2e-stub] FAILED — 匿名访问未被 gate 拦下"; cat "$OUT"; exit 1
fi
echo "[e2e-stub] OK"; cat "$OUT"
