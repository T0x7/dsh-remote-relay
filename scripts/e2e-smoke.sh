#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/dsh-relay-e2e2.XXXXXX)
OUT=$TMP/result.txt
PSK="e2e-smoke-psk-$RANDOM"
cleanup() { pkill -P $$ 2>/dev/null; lsof -ti :8083 -ti :9998 2>/dev/null | xargs kill 2>/dev/null; }
trap cleanup EXIT

# upstream "SPA"
node -e 'require("http").createServer((q,s)=>{s.setHeader("content-type","text/html");s.end("<html>ok-spa-e2e</html>")}).listen(9998,"127.0.0.1")' >/dev/null 2>&1 &
sleep 0.5
curl -s -m 3 http://127.0.0.1:9998/ | grep -q ok-spa-e2e && echo "[e2e] upstream up" >> $OUT || { echo "[e2e] FAIL: upstream dead" >> $OUT; exit 1; }

# relay server (exec so kill works)
cd $ROOT/server && HOST=127.0.0.1 PORT=8083 RELAY_PSK=$PSK RELAY_PUBLIC_HOST=127.0.0.1:8083 \
  DSH_UPSTREAM=http://127.0.0.1:9998 AUDIT_DB_PATH=$TMP/audit.db STATE_DB_PATH=$TMP/state.db \
  node dist/index.js >>$TMP/relay.log 2>&1 &
RELAY_PID=$!
for i in $(seq 1 50); do curl -sf -m 2 http://127.0.0.1:8083/health >/dev/null 2>&1 && break; sleep 0.2; done
echo "[e2e] relay /health: $(curl -s -m 3 http://127.0.0.1:8083/health)" >> $OUT

# client serve (holds tunnel)
cd $ROOT/client && DSH_REMOTE_RELAY_URL=http://127.0.0.1:8083 DSH_REMOTE_PSK=$PSK \
  DSH_BIND_PORT=9998 DSH_REMOTE_DATA_ROOT=$TMP/client node dist/cli.js serve >$TMP/serve.log 2>&1 &
SERVE_PID=$!
sleep 2
echo "[e2e] serve: $(grep -o 'state=[a-z-]*' $TMP/serve.log | head -1)" >> $OUT

# pair (one-shot, exits by itself)
cd $ROOT/client && DSH_REMOTE_RELAY_URL=http://127.0.0.1:8083 DSH_REMOTE_PSK=$PSK \
  DSH_BIND_PORT=9998 DSH_REMOTE_DATA_ROOT=$TMP/client timeout 20 node dist/cli.js pair >$TMP/pair.log 2>&1
QR_URL=$(grep -E '^http://127\.0\.0\.1:8083/\?sessionId=' $TMP/pair.log | head -1)
echo "[e2e] pair sessionId: $(grep -o 'sess_[0-9a-f]*' $TMP/pair.log | head -1)" >> $OUT
echo "[e2e] QR rendered in terminal: $(grep -c '█' $TMP/pair.log) block chars" >> $OUT
if [ -z "$QR_URL" ]; then echo "[e2e] FAIL: no QR URL" >> $OUT; head -5 $TMP/pair.log >> $OUT; exit 1; fi

sleep 3.5   # serve 的配对收养轮询（2s）把 pair 进程铸的配对经活隧道补注册
CODE=$(curl -s -L -m 15 -o $TMP/scan.html -w '%{http_code}' "$QR_URL")
echo "[e2e] GET qrUrl → $CODE, SPA bytes via data plane: $(grep -q ok-spa-e2e $TMP/scan.html && echo yes || echo NO)" >> $OUT

ANON=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8083/)
echo "[e2e] GET / anonymous → $ANON (expect 401/403)" >> $OUT

kill $RELAY_PID $SERVE_PID 2>/dev/null
echo "[e2e] DONE" >> $OUT
