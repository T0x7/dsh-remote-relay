// TLS echo endpoint for the pinning probe (plan T0.5): one self-signed
// https server with a wss upgrade — `--port <n> --cert <p> --key <p>`.
// GET /  -> {tls:true}; wss /echo -> hello + echo. Prints
// `TLS_ECHO_READY port=<p>`.
import https from 'node:https';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argOf = (name) => args[args.indexOf(name) + 1];
const port = Number(argOf('--port'));
const certPath = argOf('--cert');
const keyPath = argOf('--key');
const repoRoot = process.env.DSH_REPO_ROOT;
if (!port || !certPath || !keyPath || !repoRoot) {
  console.error('usage: tls_echo_server.mjs --port n --cert p --key p');
  process.exit(2);
}

const nodeRequire = createRequire(
    pathToFileURL(`${repoRoot}/server/package.json`));
const { WebSocketServer } = nodeRequire('ws');

const server = https.createServer(
  { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) },
  (req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ tls: true }));
  },
);

const wss = new WebSocketServer({ noServer: true, path: '/echo' });
server.on('upgrade', (req, socket, head) => {
  const { pathname } = new URL(req.url ?? '/', 'https://x');
  if (pathname === '/echo') {
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.send(JSON.stringify({ type: 'hello', transport: 'wss' }));
      ws.on('message', (data) =>
        ws.send(JSON.stringify({ type: 'echo', of: data.toString() })));
    });
    return;
  }
  socket.destroy();
});

server.listen(port, '127.0.0.1', () => {
  console.log(`TLS_ECHO_READY port=${server.address().port}`);
});
