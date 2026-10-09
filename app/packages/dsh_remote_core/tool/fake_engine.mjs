// Minimal fake dsh engine for the app integration test bed (plan T0.3 + T2.1e).
//
// HTTP (M1 surface):
//        GET /dsh-remote/session  -> card contract JSON (tunnel connected)
//        GET /api/ping            -> {pong:true}
//        GET /dsh-remote/url-session -> mint a fresh signed URL
//
// HTTP (M2 surface, T2.1e) — dsh 0.1.7-rc.2 routes the whole engine control
// plane through ONE shared channel, so the fake engine implements the same
// shape rather than one route per method:
//        POST /api                -> JSON-RPC envelope
//                                    {type:'client-request', rpcId, method, payload:{args}}
//                                    -> {type:'server-response', rpcId, result:{ok,value|error}}
//        WS   /api/remote.mux     -> multiplexed logical streams keyed by streamId
//
// The strictness here is the point of the file: the real host validates the
// envelope with `exactKeys` / zod (client/connection/src/rpc-schema.ts:35-47,
// api/gateway/src/stream-protocol.ts:264-315) and rejects a business call on a
// stream endpoint with `gateway/signature-invalid`. A permissive fake would
// pass tests the real engine fails, so every rule below is enforced.
//
// 'ws' is required from the repo's server/node_modules — the harness adds no
// new Node dependencies. Server: `node fake_engine.mjs --port <n>`, prints
// `FAKE_ENGINE_READY port=<p>` once listening.
import http from 'node:http';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const portArg = Number(args[args.indexOf('--port') + 1]);
const port = Number.isFinite(portArg) && portArg > 0 ? portArg : 0;
const hostArg = args[args.indexOf('--host') + 1];
const bindHost = hostArg && !hostArg.startsWith('--') ? hostArg : '127.0.0.1';
const repoRoot = process.env.DSH_REPO_ROOT;
if (!repoRoot) {
  console.error('fake_engine: DSH_REPO_ROOT env required');
  process.exit(2);
}

const nodeRequire = createRequire(
    pathToFileURL(`${repoRoot}/server/package.json`));
const { WebSocketServer } = nodeRequire('ws');

// ---------------------------------------------------------------------------
// Engine state (T2.1e)
// ---------------------------------------------------------------------------

const now = () => Date.now();

/** Sessions the fake engine knows about, keyed by sessionId. */
const sessions = new Map();
const ensureSession = (id) => {
  let s = sessions.get(id);
  if (!s) {
    let seq = 0;
    const nextSeq = () => (seq += 1);
    s = {
      header: {
        version: 4,
        id,
        createdAt: now(),
        cwd: '/fake/workspace',
        isSeeded: false,
      },
      records: [],
      cursor: -1,
      assistantRevision: 0,
      selection: { provider: 'deepseek-official', model: 'deepseek-v4' },
      emit(event) {
        s.records.push({
          type: 'event',
          event: { seq: nextSeq(), time: now(), ...event },
        });
        s.cursor = s.records.at(-1).event.seq;
        for (const ws of streamClients(s.followers)) ws.sendItem({ type: 'event', event: s.records.at(-1).event });
      },
      followers: new Set(),
      controlFollowers: new Set(),
    };
    sessions.set(id, s);
  }
  return s;
};

const MODEL_CATALOG = {
  default: { provider: 'deepseek-official', model: 'deepseek-v4' },
  routableProviders: ['deepseek-official'],
  groups: [
    {
      id: 'deepseek-official',
      name: 'DeepSeek',
      models: [
        {
          id: 'deepseek-v4',
          name: 'DeepSeek V4',
          reasoning: {
            efforts: [
              { id: 'low', name: 'Low' },
              { id: 'high', name: 'High' },
            ],
            defaultEffort: 'medium',
          },
        },
        { id: 'plain-model', name: 'Plain' },
      ],
    },
  ],
  // A provider that failed to report must be isolated, not break the catalog.
  failures: [{ id: 'openai', name: 'OpenAI', message: 'no API key' }],
};

const projectionsOf = (s) => ({
  asOfSeq: s.cursor,
  values: {
    modelSelection: { lastUsed: s.selection, next: s.selection },
    contextPressure: { pressureTokens: 1200, projectedTokens: 2400, contextWindow: 128000 },
    contextBreakdown: { systemTokens: 300, toolsTokens: 400, messageTokens: 500 },
    tokenUsage: {
      uncachedInputTokens: 120,
      outputTokens: 800,
      cacheReadTokens: 2000,
      cacheWriteTokens: 300,
    },
    sessionStats: {
      turns: 4,
      steps: 9,
      llmMs: 8000,
      toolMs: 1500,
      ttftMs: 3000,
      ttftSteps: 9,
      decodeMs: 2000,
      decodeTokens: 800,
    },
    subagentCatalog: [],
  },
});

const streamClients = (set) => [...set];

/** Live waterfall deliveries awaiting an answer, keyed by eventId. */
const pendingWaterfalls = new Map();

/** Answered deliveries, retained for the test inspection surface. */
const answeredDeliveries = [];

/** Registered subagent children and their lifecycle mode. */
const subagentModes = new Map();

// Endpoint table. Two facts, both verified live against dsh 0.1.7-rc.2:
//
// 1. `args` is keyed by the endpoint method's **declared parameter name** —
//    `{request: {…}}` for almost every endpoint, `{_request: {}}` for
//    `session/list` (its ignored parameter keeps the underscore). A flat
//    `{sessionId}` is refused with `gateway/arguments-invalid`.
// 2. Argument validation runs BEFORE the stream/unary signature check, so a
//    stream endpoint called with empty args reports the missing parameter
//    rather than `gateway/signature-invalid`.
//
// Both used to be implemented loosely here, which let the Dart side pass
// against a rubber stamp while failing against the real engine.
const ENDPOINTS = {
  'session/list': { field: '_request', required: [], optional: ['cursor'] },
  'session/create': { field: 'request', required: [], optional: ['workspaceId', 'cwd', 'sessionId', 'agentPreset'] },
  'session/prompt': {
    field: 'request',
    required: ['requestId', 'sessionId', 'mode', 'content'],
    optional: ['clientTimeZone'],
  },
  'session/cancel': { field: 'request', required: ['sessionId'], optional: [] },
  'session/rename': { field: 'request', required: ['sessionId', 'title'], optional: [] },
  'session/fork': { field: 'request', required: ['sessionId'], optional: ['atSeq'] },
  'session/page': { field: 'request', required: ['address', 'throughSeq'], optional: ['beforeSeq', 'maxMessages', 'turnWindow'] },
  'session/projections': { field: 'request', required: ['sessionId'], optional: [] },
  'session/modelCatalog': { field: null, required: [], optional: [] },
  'session/selectModel': { field: 'request', required: ['sessionId', 'provider', 'model'], optional: ['reasoningEffort'] },
  'subagents/prompt': {
    field: 'request',
    required: ['requestId', 'parentSessionId', 'childSessionId', 'mode', 'delivery', 'content'],
    optional: ['clientTimeZone'],
  },
  'subagents/interruptByParent': { field: 'request', required: ['childSessionId', 'parentSessionId', 'mode'], optional: [] },
  'job/kill': { field: 'request', required: ['sessionId', 'jobId'], optional: [] },
  '$events/result': { field: 'request', required: ['clientId', 'eventId', 'outcome'], optional: [] },
};

const STREAM_ENDPOINTS = new Set([
  'session/follow',
  'session/control',
  '$events',
  'job/list',
  'job/follow',
]);

// Stream endpoints that still declare a parameter object on the wire.
const STREAM_FIELDS = {
  'session/follow': 'request',
  'session/control': null,
  '$events': null,
  'job/list': 'request',
  'job/follow': 'request',
};

// Snapshot of the unary-only endpoints, taken BEFORE the stream descriptors
// are merged in below. `openStream` uses this to tell "unary endpoint opened
// as a stream" from a legitimate stream endpoint.
const UNARY_ENDPOINTS = new Set(Object.keys(ENDPOINTS));

// Unary descriptors for the stream endpoints, so a stream endpoint called
// over HTTP still validates its `args` before the signature check — the same
// ordering the real engine uses.
for (const [endpoint, field] of Object.entries(STREAM_FIELDS)) {
  if (ENDPOINTS[endpoint] === undefined) {
    const required = endpoint === 'session/follow'
      ? ['address']
      : endpoint === 'job/follow'
        ? ['jobId']
        : endpoint === 'job/list'
          ? ['sessionId']
          : [];
    const optional = endpoint === 'session/follow'
      ? ['assistantStream', 'maxMessages', 'turnWindow']
      : endpoint === 'job/follow'
        ? ['sessionId', 'from']
        : [];
    ENDPOINTS[endpoint] = { field, required, optional };
  }
}

const isPlainObject = (v) =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

const exactKeys = (value, expected) => {
  const keys = Object.keys(value);
  return keys.length === expected.length && expected.every((k) => k in value);
};

/**
 * Unwrap and validate `payload.args` against an endpoint's descriptor.
 * @returns {object|null} the business request, or a failure tuple.
 */
function unwrapArgs(method, args) {
  let spec = ENDPOINTS[method];
  if (spec === undefined && STREAM_FIELDS[method] !== undefined) {
    spec = { field: STREAM_FIELDS[method], required: [], optional: [] };
  }
  if (spec === undefined) return undefined;
  if (spec.field === null) {
    // Parameterless endpoint: the wire takes a bare `{}` inside `args`.
    return exactKeys(args, []) ? {} : ['gateway/arguments-invalid', 'endpoint takes no arguments', {}];
  }
  if (!isPlainObject(args) || !exactKeys(args, [spec.field])) {
    return [
      'gateway/arguments-invalid',
      `args fields do not match the descriptor: expected "${spec.field}"`,
      {},
    ];
  }
  const request = args[spec.field];
  if (!isPlainObject(request)) {
    return ['gateway/input-invalid', `wire field "${spec.field}" failed boundary validation`, { field: spec.field }];
  }
  for (const key of spec.required) {
    if (!(key in request)) {
      return ['gateway/arguments-invalid', `missing "${key}"`, { field: key }];
    }
  }
  for (const key of Object.keys(request)) {
    if (!spec.required.includes(key) && !spec.optional.includes(key)) {
      return ['gateway/arguments-invalid', `unexpected "${key}"`, { field: key }];
    }
  }
  return request;
}

// `value` is absent for void business methods
// (api/gateway/src/index.ts:675-679) — `ok:true` with no `value` key.
const ok = (rpcId, value) => ({
  type: 'server-response',
  rpcId,
  result: value === undefined ? { ok: true } : { ok: true, value },
});

const fail = (rpcId, code, message, details = {}) => ({
  type: 'server-response',
  rpcId,
  result: { ok: false, error: { code, message, details } },
});

const gatewayDetail = (endpoint, field) => ({
  endpoint,
  ...(field === undefined ? {} : { field }),
});

function dispatch(method, args) {
  const spec = ENDPOINTS[method];
  if (spec === undefined) return undefined;

  const keys = Object.keys(args);
  for (const key of spec.required) {
    if (!keys.includes(key)) {
      return ['gateway/arguments-invalid', `missing argument ${key}`, { field: key }];
    }
  }
  for (const key of keys) {
    if (!spec.required.includes(key) && !spec.optional.includes(key)) {
      return ['gateway/arguments-invalid', `unexpected argument ${key}`, { field: key }];
    }
  }

  switch (method) {
    case 'session/list':
      return [null, { items: [...sessions.values()].map((s) => ({
        sessionId: s.header.id,
        updatedAt: now(),
        running: false,
        blank: s.records.length === 0,
        agentAvailable: true,
        cwd: s.header.cwd,
        projections: { kind: 'sequenced', asOfSeq: s.cursor, values: projectionsOf(s).values },
      })) }];

    case 'session/create': {
      const id = args.sessionId ?? `session-${sessions.size + 1}`;
      ensureSession(id);
      return [null, { sessionId: id }];
    }

    case 'session/prompt': {
      const s = ensureSession(args.sessionId);
      // Real UserMessage shape: content blocks, not a flat `text` field
      // (core/session/src/types.ts:317, llm/llm/src/message.ts:162-164).
      s.emit({
        type: 'user/message',
        data: {
          id: `msg-${s.records.length + 1}`,
          content: (args.content ?? []).map((part) =>
            part.type === 'image'
              ? { type: 'image', attachment: { attachmentId: 'att-1', mediaType: part.mediaType, bytes: 1, width: 1, height: 1 } }
              : { type: 'text', text: part.text ?? '' }),
          source: { kind: 'user-rpc', rpcId: args.requestId },
          role: 'user',
        },
        surfaceOp: 'append',
      });
      s.emit({
        type: 'assistant/message',
        data: {
          turn: 1,
          step: 1,
          message: {
            id: `msg-a-${s.records.length + 1}`,
            content: [{ type: 'text', text: 'ack' }],
            source: { kind: 'model', provider: s.selection.provider, model: s.selection.model },
            role: 'assistant',
          },
          stream: [],
        },
        surfaceOp: 'append',
      });
      return [null, undefined];
    }

    case 'session/cancel':
      return [null, { accepted: true }];

    case 'session/rename':
      ensureSession(args.sessionId).header.title = args.title;
      return [null, { title: args.title, seq: 1 }];

    case 'session/fork':
      return [null, { sessionId: `${args.sessionId}-fork` }];

    case 'session/page': {
      const s = ensureSession(args.address?.sessionId ?? args.address?.childSessionId ?? 'session-1');
      return [null, { records: s.records, hasMore: false }];
    }

    case 'session/projections': {
      const s = sessions.get(args.sessionId);
      return [null, s === undefined ? null : projectionsOf(s)];
    }

    case 'session/modelCatalog':
      return [null, MODEL_CATALOG];

    case 'session/selectModel': {
      const s = ensureSession(args.sessionId);
      s.selection = {
        provider: args.provider,
        model: args.model,
        ...(args.reasoningEffort === undefined ? {} : { reasoningEffort: args.reasoningEffort }),
      };
      return [null, { selected: s.selection }];
    }

    case 'subagents/prompt': {
      // The App always sends the literal `continuable` — that field is the
      // client's assertion, not a request for a mode. The Host rejects based
      // on the CHILD's actual mode
      // (subagent/subagent/src/control-types.ts:132), so the fake looks the
      // child up rather than trusting the wire field.
      const childMode = subagentModes.get(args.childSessionId) ?? 'continuable';
      if (args.mode !== 'continuable' || childMode !== 'continuable') {
        return ['subagent/not-resumable', 'child is not continuable', { childSessionId: args.childSessionId }];
      }
      if (!sessions.has(args.parentSessionId)) {
        return ['subagent/parent-unavailable', 'parent agent offline', { parentSessionId: args.parentSessionId }];
      }
      return [null, { messageId: 'msg-1' }];
    }

    case 'subagents/interruptByParent':
      return [null, { accepted: true }];

    case 'job/kill':
      return [null, { outcome: 'already-finished' }];

    case '$events/result': {
      const outcome = args.outcome ?? {};
      const delivery = pendingWaterfalls.get(args.eventId);
      if (delivery === undefined) {
        return ['gateway/input-invalid', 'unknown eventId', { field: 'eventId' }];
      }
      pendingWaterfalls.delete(args.eventId);
      delivery.answered = { kind: outcome.kind, value: outcome.value };
      // Kept out of `pendingWaterfalls` on purpose: the test surface must still
      // be able to read what a given eventId was answered with.
      answeredDeliveries.push({
        eventId: args.eventId,
        kind: delivery.answered.kind,
        value: delivery.answered.value ?? null,
      });
      for (const ws of streamClients(delivery.followers)) {
        ws.sendEnd();
      }
      return [null, undefined];
    }

    default:
      return [null, undefined];
  }
}

/** Broadcast a waterfall frame to every live `$events` stream. */
function deliverWaterfall(event, request) {
  const eventId = `evt-${pendingWaterfalls.size + 1}-${now().toString(36)}`;
  const followers = new Set();
  const delivery = { event, request, eventId, answered: null, followers };
  pendingWaterfalls.set(eventId, delivery);
  for (const ws of streamClients(eventStreams)) {
    ws.sendItem({ type: 'waterfall', event, eventId, agentId: 'agent-fake', request });
    followers.add(ws);
  }
  return eventId;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://x');
  if (url.pathname === '/dsh-remote/session') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(
      JSON.stringify({
        tunnel: { state: 'connected' },
        active: null,
        sessions: [],
        devices: [],
        engine: 'fake',
      }),
    );
    return;
  }
  if (url.pathname === '/api/ping') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ pong: true, engine: 'fake' }));
    return;
  }
  // Mint a fresh signed URL with the same PSK the harness registers with —
  // lets integration tests run the FULL renewal loop (mint → new Bearer →
  // gate accepts). Only enabled when DSH_TEST_* env is provided.
  if (url.pathname === '/dsh-remote/url-session' && process.env.DSH_TEST_PSK) {
    const t = Date.now();
    const exp = t + 24 * 3600 * 1000;
    const sid = process.env.DSH_TEST_SID;
    const mid = process.env.DSH_TEST_MID;
    const hash = crypto
        .createHmac('sha256', process.env.DSH_TEST_PSK)
        .update(`${sid}|${exp}|${mid}|${t}`)
        .digest('base64url'); // unpadded — 43 chars, matches the contract
    const u = new URL(`http://${req.headers.host ?? '127.0.0.1'}/`);
    u.searchParams.set('sessionId', sid);
    u.searchParams.set('hash', hash);
    u.searchParams.set('t', String(t));
    u.searchParams.set('exp', String(exp));
    u.searchParams.set('mid', mid);
    u.searchParams.set('name', 'fake-engine-host');
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ url: u.toString() }));
    return;
  }
  if (url.pathname === '/dsh-remote/tunnel') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('true');
    return;
  }

  // ---- M2 shared channel: POST /api/<endpoint> (T2.1e) --------------------
  // The channel `/api` is a mount PREFIX: the client appends the endpoint, so
  // the real path is `/api/session/prompt`, never the bare `/api`
  // (client/connection/src/client/rpc.ts:48).
  if (url.pathname.startsWith('/api/')) {
    if (req.method !== 'POST') {
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('not found');
      return;
    }
    const pathEndpoint = url.pathname.slice('/api/'.length);
    const mediaType = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
    if (mediaType !== 'application/json') {
      res.writeHead(415, { 'content-type': 'text/plain' });
      res.end('content type must be application/json');
      return;
    }
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      const send = (payload, status = 200) => {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(JSON.stringify(payload));
      };
      let envelope;
      try {
        envelope = JSON.parse(body);
      } catch {
        res.writeHead(400, { 'content-type': 'text/plain' });
        res.end('bad request');
        return;
      }
      if (!isPlainObject(envelope) ||
          !exactKeys(envelope, ['type', 'rpcId', 'method', 'payload']) ||
          envelope.type !== 'client-request' ||
          typeof envelope.rpcId !== 'string' ||
          typeof envelope.method !== 'string') {
        send(fail('?', 'gateway/bad-request', 'invalid envelope', { issues: [] }));
        return;
      }
      const { rpcId, method, payload } = envelope;
      // The Host binds the envelope's `method` to the path it arrived on and
      // rejects a mismatch with `gateway/bad-request`
      // (client/connection/src/rpc-host.ts:252-258).
      if (method !== pathEndpoint) {
        send(fail(rpcId, 'gateway/bad-request', 'method does not match path',
          { issues: [{ path: ['method'] }] }));
        return;
      }
      if (!isPlainObject(payload) || !exactKeys(payload, ['args']) || !isPlainObject(payload.args)) {
        send(fail(rpcId, 'gateway/bad-request', 'payload must be {args}', { issues: [] }));
        return;
      }
      // Argument validation runs BEFORE the stream/unary signature check —
      // observed live on dsh 0.1.7-rc.2: `session/follow` called unary with
      // `{}` answers `missing "request"`, not `signature-invalid`.
      const unwrapped = unwrapArgs(method, payload.args);
      if (Array.isArray(unwrapped)) {
        send(fail(rpcId, unwrapped[0], `${method}: ${unwrapped[1]}`, unwrapped[2] ?? {}));
        return;
      }
      if (unwrapped === undefined) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('not found');
        return;
      }
      if (STREAM_ENDPOINTS.has(method)) {
        // A stream endpoint called unary is a signature mismatch
        // (api/gateway/src/index.ts:350-356).
        send(fail(rpcId, 'gateway/signature-invalid', 'endpoint is a stream',
          gatewayDetail(method)));
        return;
      }
      const outcome = dispatch(method, unwrapped);
      if (outcome === undefined) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('not found');
        return;
      }
      const [code, value, details] = outcome;
      if (code !== null) {
        send(fail(rpcId, code, value, details ?? {}));
        return;
      }
      send(ok(rpcId, value));
    });
    return;
  }

  // Test-only control surface, deliberately outside the engine contract.
  if (url.pathname === '/__test/waterfall' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      const spec = JSON.parse(body || '{}');
      const eventId = deliverWaterfall(spec.event ?? 'approval/request', spec.request ?? {});
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ eventId }));
    });
    return;
  }
  if (url.pathname === '/__test/answered' && req.method === 'GET') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(answeredDeliveries));
    return;
  }
  if (url.pathname === '/__test/subagent' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      const spec = JSON.parse(body || '{}');
      const childSessionId = spec.childSessionId ?? 'child-1';
      subagentModes.set(childSessionId, spec.mode ?? 'continuable');
      if (spec.parentSessionId !== undefined) {
        ensureSession(spec.parentSessionId);
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ childSessionId, mode: subagentModes.get(childSessionId) }));
    });
    return;
  }
  if (url.pathname === '/__test/session' && req.method === 'POST') {    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      const s = ensureSession(JSON.parse(body || '{}').sessionId ?? 'session-1');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ sessionId: s.header.id, cursor: s.cursor }));
    });
    return;
  }

  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: `fake engine: no route ${url.pathname}` }));
});

// ---------------------------------------------------------------------------
// Mux: /api/remote.mux (T2.1e)
// ---------------------------------------------------------------------------

/** Per-socket logical streams keyed by streamId. */
const eventStreams = new Set();

function makeMuxSocket(ws) {
  const streams = new Map();
  const handle = {
    streams,
    sendItem(value) { ws.send(JSON.stringify({ type: 'item', streamId: handle.id, value })); },
    sendEnd() { ws.send(JSON.stringify({ type: 'end', streamId: handle.id })); },
    sendError(code, message, details) {
      ws.send(JSON.stringify({
        type: 'error', streamId: handle.id, error: { code, message, details },
      }));
    },
    id: '',
  };
  return handle;
}

function openStream(ws, streams, streamId, endpoint, payload) {
  if (!isPlainObject(payload) || !exactKeys(payload, ['args'])) {
    const h = makeMuxSocket(ws);
    h.id = streamId;
    h.sendError('gateway/bad-request', 'payload must be {args}', { issues: [] });
    return;
  }
  if (UNARY_ENDPOINTS.has(endpoint)) {
    // A unary endpoint opened as a stream is the mirror-image mismatch
    // (api/gateway/src/index.ts:384-391).
    const h = makeMuxSocket(ws);
    h.id = streamId;
    h.sendError('gateway/signature-invalid', 'endpoint is unary', { endpoint });
    return;
  }
  if (!STREAM_ENDPOINTS.has(endpoint)) {
    const h = makeMuxSocket(ws);
    h.id = streamId;
    h.sendError('gateway/method-unavailable', 'no such endpoint', { endpoint });
    return;
  }

  const h = makeMuxSocket(ws);
  h.id = streamId;
  streams.set(streamId, h);
  // Stream endpoints use the same nested-args convention as unary calls.
  const unwrapped = unwrapArgs(endpoint, payload.args);
  if (Array.isArray(unwrapped)) {
    h.sendError(unwrapped[0], `${endpoint}: ${unwrapped[1]}`, unwrapped[2] ?? {});
    return;
  }
  const args = unwrapped;

  switch (endpoint) {
    case 'session/follow': {
      const id = args.address?.sessionId ?? args.address?.childSessionId;
      if (id === undefined || !sessions.has(id)) {
        // Matches the real engine: addressing an unknown session is a domain
        // failure on the stream, not a silently created one.
        h.sendError('session/not-found', `session "${id}" not found`, { sessionId: id });
        return;
      }
      const s = ensureSession(id);
      s.followers.add(h);
      // The opening snapshot is mandatory and comes exactly once.
      h.sendItem({
        type: 'snapshot',
        header: s.header,
        cursor: s.cursor,
        records: s.records,
        hasMore: false,
        projections: projectionsOf(s),
        ...(args.assistantStream === true
          ? { assistantStream: { revision: s.assistantRevision } }
          : {}),
      });
      break;
    }
    case 'session/control':
      h.sendItem({
        type: 'baseline',
        value: { projections: Object.fromEntries(
          [...sessions.entries()].map(([id, s]) => [id, projectionsOf(s)])) },
      });
      break;
    case '$events':
      eventStreams.add(h);
      // The ready frame must come first and carries the clientId every
      // answer must echo (stream-protocol.ts:34-39).
      h.clientId = 'client-fake';
      h.sendItem({ type: 'ready', clientId: h.clientId, host: { home: '/fake/home' } });
      break;
    case 'job/list':
      h.sendItem({
        type: 'rows',
        jobs: [
          { jobId: 'job-running', status: 'running', name: 'build' },
          { jobId: 'job-done', status: 'completed', name: 'test' },
          { jobId: 'job-failed', status: 'failed', name: 'lint', error: { name: 'SpawnError', code: 'ENOENT' } },
        ],
      });
      break;
    case 'job/follow':
      h.sendItem({ type: 'opened', job: { jobId: args.jobId, status: 'running' }, from: 0 });
      break;
    default:
      h.sendError('gateway/method-unavailable', 'no such endpoint', { endpoint });
  }
}

const wss = new WebSocketServer({ noServer: true });
const legacyWss = new WebSocketServer({ noServer: true, path: '/api/events.mux' });

server.on('upgrade', (req, socket, head) => {
  const { pathname } = new URL(req.url ?? '/', 'http://x');
  if (pathname === '/api/events.mux') {
    legacyWss.handleUpgrade(req, socket, head, (ws) => {
      ws.send(JSON.stringify({ type: 'hello', engine: 'fake' }));
      ws.on('message', (data) =>
        ws.send(JSON.stringify({ type: 'echo', of: data.toString() })));
    });
    return;
  }
  if (pathname !== '/api/remote.mux') {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    const streams = new Map();
    ws.on('message', (raw) => {
      let frame;
      try {
        frame = JSON.parse(raw.toString());
      } catch {
        // Parse failure is a protocol violation: close(1008)
        // (gateway/src/stream-server.ts:150-160).
        ws.close(1008, 'invalid json');
        return;
      }
      if (!isPlainObject(frame) || typeof frame.type !== 'string' ||
          typeof frame.streamId !== 'string' || frame.streamId.length === 0) {
        ws.close(1008, 'invalid frame');
        return;
      }
      switch (frame.type) {
        case 'open': {
          // Duplicate open on one streamId is the only violation that closes
          // the whole socket (gateway/src/stream-server.ts:177-179).
          if (streams.has(frame.streamId) ||
              !exactKeys(frame, ['type', 'streamId', 'endpoint', 'payload']) ||
              typeof frame.endpoint !== 'string' || frame.endpoint.length === 0) {
            ws.close(1008, 'invalid open frame');
            return;
          }
          openStream(ws, streams, frame.streamId, frame.endpoint, frame.payload);
          break;
        }
        case 'item':
          if (!exactKeys(frame, ['type', 'streamId']) &&
              !exactKeys(frame, ['type', 'streamId', 'value'])) {
            ws.close(1008, 'invalid item frame');
          }
          break;
        case 'end':
          if (!exactKeys(frame, ['type', 'streamId'])) ws.close(1008, 'invalid end frame');
          break;
        case 'cancel':
          if (!exactKeys(frame, ['type', 'streamId'])) {
            ws.close(1008, 'invalid cancel frame');
            return;
          }
          streams.get(frame.streamId)?.sendEnd();
          streams.delete(frame.streamId);
          break;
        default:
          ws.close(1008, 'unknown frame type');
      }
    });
    ws.on('close', () => {
      for (const h of streams.values()) eventStreams.delete(h);
      streams.clear();
    });
  });
});

server.listen(port, bindHost, () => {
  console.log(`FAKE_ENGINE_READY port=${server.address().port}`);
});

