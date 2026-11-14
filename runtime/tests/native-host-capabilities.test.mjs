// v1.4 host capability tests for dsh-go-bridge (docs/design/native-plugins-protocol.md §13):
// plugin → bridge → app (`host.req`/`host.res`) → back, over a real HTTP/WebSocket bridge.
//   node --test runtime/tests/native-host-capabilities.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { connect } from 'node:net';
import { mkdtempSync, writeFileSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { once } from 'node:events';
import { apply } from '../bridge/dsh-go-bridge/lib/index.js';
import { encodeFrame } from '../bridge/dsh-go-bridge/lib/native/ws.js';

const manifest = {
  v: 1,
  capabilities: ['sessionText', 'selection', 'send', 'notify', 'phone', 'tools', 'schedule', 'pluginFiles'],
  contributes: {
    'composer.actions': [{ id: 'go', label: 'Go' }],
    panels: [{ id: 'panel', title: 'Panel' }],
  },
};

async function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-host-'));
  const home = join(dir, 'home');
  const previousHome = process.env.DSH_HOME;
  process.env.DSH_HOME = home;
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'host-test', version: '1.0.0', dshGo: manifest }));
  writeFileSync(join(dir, 'index.js'), '');
  const disposers = [], routes = [], upgrades = [], hooks = new Map(), services = {};
  const entry = {
    options: { name: pathToFileURL(join(dir, 'index.js')).href },
    parent: { tree: { ctx: { baseUrl: pathToFileURL(dir + '/').href } } },
    fiber: { uid: 7 },
  };
  const entries = [entry];
  const connection = { requestRejection() {} };
  services.tools = {
    async execute({ calls }) {
      return {
        results: [{
          callId: calls[0].id,
          result: { content: [{ type: 'text', text: `TOOL:${calls[0].name}:${calls[0].arguments}` }] },
        }],
        additionalContexts: [],
        concluded: false,
      };
    },
  };
  const ctx = {
    logger: { warn() {} },
    get: (n) => n === 'loader' ? { entries: () => entries } : n === 'connection' ? connection : services[n],
    provide(n, s) { services[n] = s; },
    effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d); return d; },
    on(n, fn) { hooks.set(n, fn); },
    inject(deps, fn) { fn(ctx); },
    webServer: {
      tapIndex() { return () => {}; },
      register(r) { routes.push(r); return () => {}; },
      registerUpgrade(r) { upgrades.push(r); return () => {}; },
    },
  };
  apply(ctx, { persist: false, guardRoutes: false, native: { handlerTimeoutMs: 2000 } });
  const server = createServer((req, res) => {
    const r = routes.find((r) => r.kind === 'prefix' && req.url.startsWith(r.path));
    if (r) r.handler(req, res);
    else { res.writeHead(404); res.end(); }
  });
  server.on('upgrade', (req, socket, head) => upgrades[0].handler(req, socket, head));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  const pluginCtx = { fiber: { entry }, effect: ctx.effect };
  const service = Object.assign(Object.create(services.dshGo), { ctx: pluginCtx });
  const sockets = new Set();
  const hostRequests = [];
  let hostHandler = () => ({ ok: true });
  let hostWaiter;

  async function ws(features) {
    const socket = connect(port, '127.0.0.1');
    sockets.add(socket);
    await once(socket, 'connect');
    const messages = [], waiters = [];
    let buffer = Buffer.alloc(0), handshake = false;
    const deliver = (m) => {
      if (m.t === 'host.req') {
        hostRequests.push(m);
        const reply = hostHandler(m);
        if (reply !== undefined) out.send({ t: 'host.res', id: m.id, ...reply });
        hostWaiter?.();
        hostWaiter = undefined;
      }
      const i = waiters.findIndex((w) => w.p(m));
      if (i < 0) messages.push(m);
      else { const [w] = waiters.splice(i, 1); clearTimeout(w.timer); w.r(m); }
    };
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!handshake) {
        const i = buffer.indexOf('\r\n\r\n');
        if (i < 0) return;
        buffer = buffer.subarray(i + 4);
        handshake = true;
      }
      while (buffer.length >= 2) {
        const op = buffer[0] & 15;
        let n = buffer[1] & 127, off = 2;
        if (n === 126) { if (buffer.length < 4) return; n = buffer.readUInt16BE(2); off = 4; }
        if (n === 127 || buffer.length < off + n) return;
        const data = buffer.subarray(off, off + n);
        buffer = buffer.subarray(off + n);
        if (op === 1) deliver(JSON.parse(data.toString()));
      }
    });
    socket.write('GET /dsh-go/v1/stream HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n');
    const out = {
      socket,
      send: (m) => socket.write(encodeFrame(1, JSON.stringify(m), { mask: true })),
      next(p) {
        const i = messages.findIndex(p);
        if (i >= 0) return Promise.resolve(messages.splice(i, 1)[0]);
        return new Promise((r, reject) => {
          const w = { p, r };
          w.timer = setTimeout(() => reject(new Error('message timeout')), 4000);
          waiters.push(w);
        });
      },
    };
    out.send({ t: 'hello', v: [1], ...(features === undefined ? {} : { features }) });
    out.welcome = await out.next((m) => m.t === 'welcome');
    return out;
  }

  const request = (path, options = {}) => fetch(`http://127.0.0.1:${port}/dsh-go/v1/${path}`, {
    ...options,
    headers: { authorization: 'Bearer test', ...options.headers },
  });
  const invoke = async (w) => {
    const response = await request('invoke', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: 1, pkg: 'host-test', id: 'go', surface: 'composer.actions', scope: { sessionId: 's1' }, stream: w?.welcome.conn }),
    });
    return { status: response.status, ...await response.json() };
  };

  t.after(async () => {
    for (const s of sockets) s.destroy();
    while (disposers.length) disposers.pop()();
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
    if (previousHome === undefined) delete process.env.DSH_HOME;
    else process.env.DSH_HOME = previousHome;
    rmSync(dir, { recursive: true, force: true });
  });

  return {
    service, ws, invoke, home, dir,
    onHost(fn) { hostHandler = fn; },
    hostRequests: () => hostRequests,
    waitForHost() { return hostRequests.length > 0 ? Promise.resolve() : new Promise((r) => { hostWaiter = r; }); },
  };
}

/** Invokes a handler that uses one capability; the fake app answers every host request. */
async function roundTrip(t, { features, answer, call }) {
  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      const value = await call(f.service);
      return { copy: JSON.stringify({ ok: true, value: value ?? null }) };
    } catch (error) {
      return { copy: JSON.stringify({ ok: false, code: error.code, message: error.message }) };
    }
  });
  f.onHost(answer);
  const w = await f.ws(features);
  const result = await f.invoke(w);
  const copied = result.effects.find((e) => e.type === 'copy');
  assert.ok(copied, `expected a copy effect, got ${JSON.stringify(result)}`);
  return { f, w, result, peer: JSON.parse(copied.text), requests: f.hostRequests() };
}

test('the app answers sessionText and the plugin gets the value', async (t) => {
  const { requests, peer } = await roundTrip(t, {
    features: ['sessionText'],
    answer: () => ({ ok: true, value: { text: 'hello from the app' } }),
    call: (service) => service.capability('sessionText', { limit: 100 }),
  });
  assert.equal(requests[0].cap, 'sessionText');
  assert.deepEqual(requests[0].payload, { limit: 1000 });
  assert.deepEqual(peer, { ok: true, value: { text: 'hello from the app' } });
});

test('an undeclared capability is refused without asking the app', async (t) => {
  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      await f.service.capability('audio');
      return { toast: 'no' };
    } catch (error) {
      return { toast: `code:${error.code}` };
    }
  });
  const w = await f.ws(['audio']);
  const result = await f.invoke(w);
  assert.equal(result.effects[0].text, 'code:unsupported');
});

test('a declared capability the app did not negotiate is refused', async (t) => {
  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      await f.service.capability('selection');
      return { toast: 'no' };
    } catch (error) {
      return { toast: `code:${error.code}` };
    }
  });
  const w = await f.ws([]);
  const result = await f.invoke(w);
  assert.equal(result.effects[0].text, 'code:unsupported');
});

test('no stream means no capability call', async (t) => {
  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      await f.service.capability('selection');
      return { toast: 'no' };
    } catch (error) {
      return { toast: `code:${error.code}` };
    }
  });
  const result = await f.invoke(undefined);
  assert.equal(result.effects[0].text, 'code:unsupported');
});

test('a denial reaches the plugin with the app\'s code', async (t) => {
  const { peer } = await roundTrip(t, {
    features: ['notify'],
    answer: () => ({ ok: false, code: 'denied', message: 'the person said no' }),
    call: (service) => service.capability('notify', { title: 'Hi', text: 'there' }),
  });
  assert.equal(peer.ok, false);
  assert.equal(peer.code, 'denied');
  assert.equal(peer.message, 'the person said no');
});

test('send and notify are actions: an ok answer is enough', async (t) => {
  const { requests, peer } = await roundTrip(t, {
    features: ['send', 'notify'],
    answer: () => ({ ok: true }),
    call: async (service) => {
      const a = await service.capability('send', { text: 'draft text' });
      const b = await service.capability('notify', { title: 'T', text: 'B', attention: true });
      return [a, b];
    },
  });
  assert.deepEqual(requests.map((r) => r.cap), ['send', 'notify']);
  assert.deepEqual(requests[0].payload, { text: 'draft text' });
  assert.deepEqual(peer.value, [true, true]);
});

test('phone only calls mcp__phone__* tools, tools runs any engine tool', async (t) => {
  const { requests, peer } = await roundTrip(t, {
    features: ['tools'],
    answer: () => ({ ok: true }),
    call: (service) => service.capability('tools', { tool: 'web_search', args: { queries: ['a'] } }),
  });
  assert.equal(requests[0].cap, 'tools');
  assert.match(requests[0].payload.summary, /web_search/);
  assert.equal(peer.value.text, 'TOOL:web_search:{"queries":["a"]}');

  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      await f.service.capability('phone', { tool: 'bash', args: {} });
      return { toast: 'no' };
    } catch (error) {
      return { toast: `code:${error.code}` };
    }
  });
  const w = await f.ws(['phone']);
  assert.equal((await f.invoke(w)).effects[0].text, 'code:bad-request');
});

test('phone runs a phone tool after the app allows it', async (t) => {
  const { peer } = await roundTrip(t, {
    features: ['phone'],
    answer: () => ({ ok: true }),
    call: (service) => service.capability('phone', { tool: 'mcp__phone__screen' }),
  });
  assert.equal(peer.value.text, 'TOOL:mcp__phone__screen:{}');
});

test('pluginFiles keeps everything inside the plugin data directory', async (t) => {
  const { f, requests, peer } = await roundTrip(t, {
    features: ['pluginFiles'],
    answer: () => ({ ok: true }),
    call: async (service) => {
      await service.capability('pluginFiles', { op: 'write', path: 'notes/a.txt', text: 'hello' });
      return service.capability('pluginFiles', { op: 'read', path: 'notes/a.txt' });
    },
  });
  assert.equal(requests[0].cap, 'pluginFiles');
  assert.match(requests[0].payload.summary, /write notes\/a.txt/);
  assert.equal(peer.value.text, 'hello');
  const onDisk = join(f.home, 'dsh-go', 'plugins', 'host-test', 'data', 'notes', 'a.txt');
  assert.ok(existsSync(onDisk));
  assert.equal(readFileSync(onDisk, 'utf8'), 'hello');
});

test('pluginFiles refuses a path that leaves the directory before asking the app', async (t) => {
  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      await f.service.capability('pluginFiles', { op: 'read', path: '../../etc/passwd' });
      return { toast: 'no' };
    } catch (error) {
      return { toast: `code:${error.code}` };
    }
  });
  const w = await f.ws(['pluginFiles']);
  assert.equal((await f.invoke(w)).effects[0].text, 'code:denied');
});

test('an oversized argument is refused before it reaches the app', async (t) => {
  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      await f.service.capability('send', { text: 'x'.repeat(5000) });
      return { toast: 'no' };
    } catch (error) {
      return { toast: `code:${error.code}` };
    }
  });
  const w = await f.ws(['send']);
  assert.equal((await f.invoke(w)).effects[0].text, 'code:too-large');
});

test('a dropped stream refuses the waiting call instead of hanging', async (t) => {
  const f = await fixture(t);
  f.service.on('go', async () => {
    try {
      await f.service.capability('sessionText');
      return { toast: 'no' };
    } catch (error) {
      return { toast: `code:${error.code}` };
    }
  });
  f.onHost(() => undefined);   // no answer: the app goes away instead
  const w = await f.ws(['sessionText']);
  const invoking = f.invoke(w);
  await f.waitForHost();
  w.socket.destroy();
  const result = await invoking;
  assert.equal(result.effects[0].text, 'code:unavailable');
});

test('a deferred result can use capabilities too (rec reaches startPending)', async (t) => {
  const f = await fixture(t);
  f.service.on('go', () => ({
    pending: { label: 'working' },
    result: async () => {
      try {
        f.service.progress('第 2 步');
        const value = await f.service.capability('selection');
        return { copy: JSON.stringify({ ok: true, value }) };
      } catch (error) {
        return { copy: JSON.stringify({ ok: false, code: error.code, message: error.message }) };
      }
    },
  }));
  f.onHost(() => ({ ok: true, value: { text: 'deferred selection' } }));
  const w = await f.ws(['selection']);
  const invoked = await f.invoke(w);
  assert.ok(invoked.pending, JSON.stringify(invoked));
  const label = await w.next((m) => m.t === 'pending.label');
  assert.equal(label.pending, invoked.pending.id);
  assert.equal(label.label, '第 2 步');
  const done = await w.next((m) => m.t === 'done');
  const copied = done.effects.find((e) => e.type === 'copy');
  assert.ok(copied, JSON.stringify(done));
  assert.deepEqual(JSON.parse(copied.text), { ok: true, value: { text: 'deferred selection' } });
});
