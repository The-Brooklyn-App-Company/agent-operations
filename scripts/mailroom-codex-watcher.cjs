// mailroom-codex-watcher.cjs - EXPERIMENTAL: the Codex side's tier 1.
//
// Usage (from the Codex bridge chat's own command session, never detached;
// normally through `mailroom.sh arm-codex`):
//   <app's bundled node> mailroom-codex-watcher.cjs --dir RING_DIR --server SERVER_MJS
//
// It relies on an undocumented interface of the Codex desktop app: the
// bundled codex-app-tools MCP server (SERVER_MJS), which reaches the app over
// a pipe the app provides only to commands started inside one of its chats.
// So it dies when the app restarts and must be re-armed by the bridge chat
// (the supervisor asks once per app process: that re-arm turn is tier 2).
//
// Before watching it opens the MCP connection and checks it: the tool list
// must have send_message_to_thread and read_thread, and read_thread on its
// own chat (CODEX_THREAD_ID, or --self-thread) must succeed. It records a
// fingerprint of the tool server (.watcher/fingerprint: a hash of the tool
// list, the server's name and version) for the supervisor's version check.
// Then it watches RING_DIR (fs.watch, debounced) and handles waiting rings
// serially, oldest name first, including any already waiting at start:
//   <thread>--<label>--steer.md  sent at once (it may land mid-turn)
//   <thread>--<label>--queue.md  sent when the target is idle; while it is
//                                busy (or its state cannot be read) the ring
//                                is held and the watcher tails the target's
//                                rollout file: each new turn-complete event
//                                triggers one state read, and the ring goes
//                                out once the target is idle. No polling.
//                                Later queue rings to the same target wait
//                                behind it. No rollout found, or still busy
//                                after 10 min: released to tier 3 (the
//                                supervisor's CLI queue) with the step.
//   echo--canary-*               the supervisor's canary: one read_thread on
//                                the bridge's own chat, filed ok or failed
// A send is one send_message_to_thread call to the target thread with the
// text `Doorbell [<ring name>]: <ring body>` (the native tool has no mode:
// queue versus steer is decided here). Each handled ring moves to
// delivered/ with one row in delivered/log.tsv (format: lib/mailroom.sh):
//   ISO-time epoch ring tier mode status latency-ms step
// tier is t1-native, or t2-bridge for a ring that waited while the watcher
// was down (the re-arm turn's catch-up). status is ok, or unknown after any
// send that did not come back with a tool answer (a timeout, a protocol
// error, a crash or a closed pipe): never re-sent by the watcher; marked in
// .watcher/unknown/ for the supervisor, which reads the target's rollout
// 5 minutes later and escalates once only when the ring is absent there. Each ring is
// claimed into .watcher/sending/ by an atomic rename before its send, so the
// supervisor's tier 3 cannot send it too. A ring whose send fails twice is
// released to tier 3 (step send-error).
//
// Health: .watcher/heartbeat (ISO time and pid) every 60 s; .watcher/log.
// Start it only through `mailroom.sh arm-codex`, whose kernel lock makes it
// the one watcher per RING_DIR (.watcher/pid is for status). It exits
// non-zero, with a log line, when the app pipe closes or three sends in a
// row fail: no spinning.
//
// Exit codes: 0 stopped by a signal; 1 connection lost or repeated failure;
// 2 usage or preflight error; 3 another watcher is running.
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const readline = require('node:readline');

const ms = (name, dflt) => {
  const v = Number(process.env[name]);
  return Number.isFinite(v) && v > 0 ? v : dflt;
};
// Overridable for tests only.
const HEARTBEAT_MS = ms('AO_MR_HEARTBEAT_MS', 60000);
const HOLD_CAP_MS = ms('AO_MR_HOLD_CAP_MS', 600000);
const CALL_TIMEOUT_MS = ms('AO_MR_CALL_TIMEOUT_MS', 30000);
const DEBOUNCE_MS = 150;
const MAX_ERRORS_IN_A_ROW = 3;
const MAX_TRIES_PER_RING = 2;
const MAX_LINE = 1 << 20;
const BUSY = /progress|running|active|started|pending/i;
const SAFE = /^[A-Za-z0-9._-]+$/;

class Unknown extends Error {}

function parseArgs(argv) {
  const a = { dir: '', server: '', self: process.env.CODEX_THREAD_ID || '' };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i], v = argv[i + 1];
    if (k === '--dir' && v) { a.dir = v; i++; }
    else if (k === '--server' && v) { a.server = v; i++; }
    else if (k === '--self-thread' && v) { a.self = v; i++; }
    else return null;
  }
  return a.dir && a.server ? a : null;
}

const args = parseArgs(process.argv.slice(2));
if (!args) {
  process.stderr.write('usage: mailroom-codex-watcher.cjs --dir RING_DIR --server SERVER_MJS [--self-thread ID]\n');
  process.exit(2);
}
const DIR = path.resolve(args.dir);
const STATE = path.join(DIR, '.watcher');
const HOLDS = path.join(STATE, 'holding');
const SENDING = path.join(STATE, 'sending');
const RELEASED = path.join(STATE, 'released');
const UNKNOWN = path.join(STATE, 'unknown');
const DELIVERED = path.join(DIR, 'delivered');
const PIDFILE = path.join(STATE, 'pid');
const SESSIONS = path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'sessions');
const STARTED = Date.now();

const iso = () => new Date().toISOString();
function log(line) {
  try { fs.appendFileSync(path.join(STATE, 'log'), `${iso()} ${line}\n`); } catch (_) { /* best effort */ }
}
function writeAtomic(file, text) {
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

// ------------------------------------------------------------- MCP client

class AppTools {
  constructor(server) {
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
    this.child = spawn(process.execPath, [server], { stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
    this.child.stderr.on('data', (b) => log(`server: ${String(b).trim().slice(0, 300)}`));
    readline.createInterface({ input: this.child.stdout }).on('line', (line) => {
      let msg;
      try { msg = JSON.parse(line); } catch (_) { return; }
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
      else p.resolve(msg.result);
    });
    this.child.on('error', (e) => this.lost(e));
    this.child.on('exit', () => this.lost(new Error('app tools server exited (app pipe closed?)')));
    this.child.stdin.on('error', (e) => this.lost(e));
  }
  lost(err) {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(err); }
    this.pending.clear();
    if (this.onLost) this.onLost(err);
  }
  request(method, params) {
    if (this.closed) return Promise.reject(new Error('app tools connection closed'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Unknown(`${method} timed out; outcome unknown`));
      }, CALL_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });
  }
  async initialize() {
    const r = await this.request('initialize', {
      protocolVersion: '2025-06-18', capabilities: {},
      clientInfo: { name: 'agent-operations-mailroom', version: '0.3.1' },
    });
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
    return r || {};
  }
  call(name, a) {
    return this.request('tools/call', { name, arguments: a, _meta: { threadId: args.self } });
  }
  close() {
    this.closed = true;
    try { this.child.kill(); } catch (_) { /* gone */ }
  }
}

// ------------------------------------------------------------- state

let app = null;
let draining = false;
let again = false;
let errorsInARow = 0;
let debounce = null;
const tries = new Map();
const released = new Set();
const watching = new Map(); // ring name -> { thread, close() }: a hold tailing its target's rollout

function shutdown(code, why) {
  log(`stopping (${code}): ${why}`);
  for (const w of watching.values()) w.close();
  try { if (fs.readFileSync(PIDFILE, 'utf8').trim() === String(process.pid)) fs.unlinkSync(PIDFILE); } catch (_) { /* none */ }
  if (app) app.close();
  process.exit(code);
}

function heartbeat() {
  try { writeAtomic(path.join(STATE, 'heartbeat'), `${iso()} ${process.pid}\n`); }
  catch (e) { log(`heartbeat failed: ${e.message}`); }
}

function waitingRings() {
  let names;
  try { names = fs.readdirSync(DIR); } catch (e) { shutdown(1, `cannot read ${DIR}: ${e.message}`); }
  return names.filter((n) => n.endsWith('.md') && !n.startsWith('.') && SAFE.test(n)
    && fs.lstatSync(path.join(DIR, n), { throwIfNoEntry: false })?.isFile()).sort();
}

function fileRing(name, tier, mode, status, step = '-', from = DIR) {
  fs.mkdirSync(DELIVERED, { recursive: true });
  const src = path.join(from, name);
  let pub = Date.now();
  try { pub = fs.statSync(src).mtimeMs; } catch (_) { /* gone below */ }
  try { fs.renameSync(src, path.join(DELIVERED, name)); }
  catch (e) { if (e.code === 'ENOENT') return false; throw e; }
  const now = new Date();
  fs.appendFileSync(path.join(DELIVERED, 'log.tsv'),
    `${now.toISOString()}\t${Math.floor(now.getTime() / 1000)}\t${name}\t${tier}\t${mode}\t${status}\t${Math.max(0, Math.round(now.getTime() - pub))}\t${step}\n`);
  dropHold(name);
  if (status === 'unknown') {
    // An alarm obligation the supervisor discharges once.
    try { fs.mkdirSync(UNKNOWN, { recursive: true }); fs.writeFileSync(path.join(UNKNOWN, name), ''); } catch (_) { /* best effort */ }
  }
  log(`filed ${name} tier=${tier} mode=${mode} status=${status} step=${step}`);
  return true;
}

function holdSince(name) {
  try { return Number(fs.readFileSync(path.join(HOLDS, name), 'utf8').trim()) * 1000; }
  catch (_) { return 0; }
}
function dropHold(name) {
  const w = watching.get(name);
  if (w) { w.close(); watching.delete(name); }
  try { fs.unlinkSync(path.join(HOLDS, name)); } catch (_) { /* none */ }
}
// release NAME STEP  Leave a ring to tier 3 for good: recorded with its step
// in .watcher/released/, so a restarted watcher does not take it up again
// and the supervisor logs why.
function release(name, step) {
  released.add(name);
  dropHold(name);
  try { fs.mkdirSync(RELEASED, { recursive: true }); fs.writeFileSync(path.join(RELEASED, name), `${step}\n`); } catch (_) { /* best effort */ }
  log(`released ${name} to tier 3: ${step}`);
}

// threadState THREAD  'busy', 'idle' or 'unknown' from the target's latest
// turn status as read_thread reports it (shape not documented: unverified).
async function threadState(thread) {
  let res;
  try {
    res = await app.call('read_thread', { threadId: thread, turnLimit: 1, includeOutputs: false, maxOutputCharsPerItem: 0 });
  } catch (e) {
    if (app.closed) throw e;
    return 'unknown';
  }
  if (!res || res.isError) return 'unknown';
  let data;
  try { data = JSON.parse(((res.content || []).find((c) => c.type === 'text') || {}).text || ''); }
  catch (_) { return 'unknown'; }
  const turns = (data && (data.turns || (data.thread && data.thread.turns))) || [];
  const last = Array.isArray(turns) && turns.length ? turns[turns.length - 1] : null;
  const st = last && (typeof last.status === 'string' ? last.status : last.status && last.status.type);
  if (typeof st !== 'string') return 'unknown';
  return BUSY.test(st) ? 'busy' : 'idle';
}

// findRollout THREAD  The target's rollout file (sessions/YYYY/MM/DD/
// rollout-*-THREAD.jsonl), newest day first, read-only; null when none.
function findRollout(thread) {
  const list = (d) => { try { return fs.readdirSync(d).sort().reverse(); } catch (_) { return []; } };
  const suffix = `-${thread}.jsonl`;
  for (const y of list(SESSIONS)) {
    for (const m of list(path.join(SESSIONS, y))) {
      for (const d of list(path.join(SESSIONS, y, m))) {
        const dir = path.join(SESSIONS, y, m, d);
        const hit = list(dir).find((f) => f.startsWith('rollout-') && f.endsWith(suffix));
        if (hit) {
          const p = path.join(dir, hit);
          if (fs.lstatSync(p, { throwIfNoEntry: false })?.isFile()) return p;
        }
      }
    }
  }
  return null;
}

// tail NAME THREAD FILE  Watch FILE from its current end; each new complete
// turn-complete line ends the wait (the ring is then re-checked by a drain).
// A replaced or removed file is looked up again; none left: release.
function tail(name, thread, file) {
  let pos = fs.statSync(file).size;
  let part = '';
  let fw = null;
  let closed = false;
  const close = () => { closed = true; try { if (fw) fw.close(); } catch (_) { /* closed */ } };
  const done = (why) => {
    if (closed) return;
    close();
    watching.delete(name);
    log(`turn complete for ${thread} (${why}); checking ${name}`);
    kick();
  };
  const read = () => {
    if (closed) return;
    let st;
    try { st = fs.statSync(file); } catch (_) { return rebind(); }
    if (st.size < pos) { pos = 0; part = ''; return done('rollout truncated'); }
    if (st.size === pos) return;
    const fd = fs.openSync(file, 'r');
    try {
      const buf = Buffer.alloc(Math.min(st.size - pos, 4 * MAX_LINE));
      const n = fs.readSync(fd, buf, 0, buf.length, pos);
      pos += n;
      const lines = (part + buf.subarray(0, n).toString('utf8')).split('\n');
      part = lines.pop();
      if (part.length > MAX_LINE) part = '';
      for (const l of lines) {
        if (!l.includes('task_complete')) continue;
        let ev;
        try { ev = JSON.parse(l); } catch (_) { continue; }
        if (ev && ev.type === 'event_msg' && ev.payload && ev.payload.type === 'task_complete') return done('task_complete');
      }
    } finally { fs.closeSync(fd); }
  };
  const rebind = () => {
    if (closed) return;
    close();
    const again = findRollout(thread);
    if (!again) { watching.delete(name); release(name, 'no-rollout'); return; }
    closed = false;
    file = again;
    done('rollout replaced');
  };
  try {
    fw = fs.watch(file, (ev) => { if (ev === 'rename') rebind(); else read(); });
    fw.on('error', () => rebind());
  } catch (_) { release(name, 'no-rollout'); return; }
  watching.set(name, { thread, close });
}

function kick() {
  clearTimeout(debounce);
  debounce = setTimeout(drain, DEBOUNCE_MS);
}

// hold NAME THREAD STATE  Keep a queue ring until its target's next turn
// completes; the 10-minute cap counts from the first hold (kept across
// restarts) and is enforced by one timer, not a poll.
function hold(name, thread, state) {
  let since = holdSince(name);
  if (!since) {
    since = Date.now();
    fs.mkdirSync(HOLDS, { recursive: true });
    writeAtomic(path.join(HOLDS, name), `${Math.floor(since / 1000)}\n`);
    log(`holding ${name}: target ${state}`);
  }
  if (Date.now() - since >= HOLD_CAP_MS) { release(name, 'queue-cap'); return; }
  if (watching.has(name)) return;
  const file = findRollout(thread);
  if (!file) { release(name, 'no-rollout'); return; }
  tail(name, thread, file);
  const t = setTimeout(() => {
    if (watching.has(name) && fs.existsSync(path.join(DIR, name))) release(name, 'queue-cap');
  }, HOLD_CAP_MS - (Date.now() - since));
  t.unref();
}

async function canary(name) {
  let ok = false;
  try {
    const r = await app.call('read_thread', { threadId: args.self, turnLimit: 1, includeOutputs: false, maxOutputCharsPerItem: 0 });
    ok = Boolean(r && !r.isError);
  } catch (e) {
    if (app.closed) throw e;
  }
  fileRing(name, 't1-native', 'canary', ok ? 'ok' : 'failed', ok ? '-' : 'read-thread');
}

async function handle(name, heldTargets) {
  const file = path.join(DIR, name);
  if (name.startsWith('echo--canary-')) { await canary(name); return; }
  if (name.startsWith('echo--')) { fileRing(name, 'none', 'echo', 'ok'); return; }
  const thread = name.split('--')[0];
  const mode = name.endsWith('--steer.md') ? 'steer' : 'queue';
  if (mode === 'queue') {
    // FIFO per target: a later queue ring waits behind a held one.
    if (heldTargets.has(thread)) return;
    if (watching.has(name)) { heldTargets.add(thread); return; }
    const state = await threadState(thread);
    // Unknown counts as busy: a queue ring is sent only to a thread seen idle.
    if (state !== 'idle') {
      hold(name, thread, state);
      if (watching.has(name)) heldTargets.add(thread);
      return;
    }
  }
  let mtime = Date.now();
  try { mtime = fs.statSync(file).mtimeMs; } catch (_) { /* taken */ }
  const caughtUp = mtime < STARTED - 1000 && !holdSince(name);
  // Claim the ring (an atomic rename) so tier 3 cannot send it too; a ring
  // someone else took is skipped.
  const claimed = path.join(SENDING, name);
  try { fs.renameSync(file, claimed); } catch (e) { if (e.code === 'ENOENT') { dropHold(name); return; } throw e; }
  const tier = caughtUp ? 't2-bridge' : 't1-native';
  const step = caughtUp ? 'watcher-down' : '-';
  const body = fs.readFileSync(claimed, 'utf8').trim();
  let res;
  try {
    res = await app.call('send_message_to_thread', { threadId: thread, hostId: 'local', prompt: `Doorbell [${name}]: ${body}` });
  } catch (e) {
    // A timeout, a protocol error or a closed pipe may come after the app
    // took the message: never re-sent automatically (K-28).
    log(`send outcome unknown for ${name}: ${e.message}`);
    fileRing(name, tier, mode, 'unknown', step, SENDING);
    if (app.closed) throw e;
    return;
  }
  if (res && !res.isError) {
    errorsInARow = 0;
    tries.delete(name);
    fileRing(name, tier, mode, 'ok', step, SENDING);
    return;
  }
  // The tool itself answered with an error (for example an unknown thread):
  // a clear refusal, so the ring goes back for the next try or tier 3.
  try { fs.renameSync(claimed, file); } catch (e) { log(`cannot return ${name}: ${e.message}`); }
  errorsInARow++;
  const n = (tries.get(name) || 0) + 1;
  tries.set(name, n);
  log(`send failed for ${name} (try ${n}): ${JSON.stringify(res && res.content).slice(0, 300)}`);
  if (n >= MAX_TRIES_PER_RING) release(name, 'send-error');
  if (errorsInARow >= MAX_ERRORS_IN_A_ROW) shutdown(1, `${errorsInARow} sends in a row failed`);
}

async function drain() {
  if (draining) { again = true; return; }
  draining = true;
  try {
    do {
      again = false;
      const heldTargets = new Set();
      for (const name of waitingRings()) {
        if (released.has(name)) continue;
        await handle(name, heldTargets);
      }
    } while (again);
  } catch (e) {
    shutdown(1, `delivery stopped: ${e.message}`);
  } finally {
    draining = false;
  }
  // Holds whose ring is gone (filed by tier 3 meanwhile) are dropped.
  let held = [];
  try { held = fs.readdirSync(HOLDS).filter((n) => !n.includes('.tmp.')); } catch (_) { /* none */ }
  for (const n of held) if (!fs.existsSync(path.join(DIR, n))) dropHold(n);
}

async function main() {
  if (!args.self) { process.stderr.write('no CODEX_THREAD_ID: run this from the bridge chat\'s own command session\n'); process.exit(2); }
  if (!fs.statSync(DIR, { throwIfNoEntry: false })?.isDirectory()) { process.stderr.write(`not a directory: ${DIR}\n`); process.exit(2); }
  if (!fs.existsSync(args.server)) { process.stderr.write(`server not found: ${args.server}\n`); process.exit(2); }
  for (const d of [HOLDS, SENDING, DELIVERED, RELEASED]) fs.mkdirSync(d, { recursive: true });
  // Pid for status only: the kernel lock `mailroom.sh arm-codex` holds
  // through exec is what makes this the only watcher.
  writeAtomic(PIDFILE, `${process.pid}\n`);
  // Holds keep their start time across restarts (the 10-minute cap is per
  // ring, not per watcher); releases stay released while the ring waits.
  for (const f of fs.readdirSync(RELEASED)) {
    if (fs.existsSync(path.join(DIR, f))) released.add(f); else fs.unlinkSync(path.join(RELEASED, f));
  }
  for (const f of fs.readdirSync(HOLDS)) if (!fs.existsSync(path.join(DIR, f))) dropHold(f);
  // A send interrupted by a crash may have landed: filed as unknown, never re-sent.
  for (const f of fs.readdirSync(SENDING)) if (f.endsWith('.md')) fileRing(f, 't1-native', 'interrupted', 'unknown', 'interrupted', SENDING);
  process.on('SIGTERM', () => shutdown(0, 'SIGTERM'));
  process.on('SIGINT', () => shutdown(0, 'SIGINT'));
  process.on('SIGHUP', () => shutdown(0, 'SIGHUP'));

  app = new AppTools(args.server);
  app.onLost = (e) => shutdown(1, `connection lost: ${e.message}`);
  try {
    const info = await app.initialize();
    const list = await app.request('tools/list', {});
    const tools = (list && list.tools) || [];
    const names = new Set(tools.map((t) => t.name));
    for (const t of ['send_message_to_thread', 'read_thread']) if (!names.has(t)) throw new Error(`tool ${t} missing`);
    const pre = await app.call('read_thread', { threadId: args.self, turnLimit: 1, includeOutputs: false, maxOutputCharsPerItem: 0 });
    if (!pre || pre.isError) throw new Error('read_thread preflight on the bridge chat failed');
    const shape = JSON.stringify(tools.map((t) => [t.name, t.inputSchema || null]).sort((a, b) => (a[0] < b[0] ? -1 : 1)));
    const si = info.serverInfo || {};
    const clean = (v) => String(v || 'unknown').replace(/[^A-Za-z0-9._-]/g, '-');
    writeAtomic(path.join(STATE, 'fingerprint'),
      `tools=${crypto.createHash('sha256').update(shape).digest('hex').slice(0, 12)} server=${clean(si.name)}-${clean(si.version)}\n`);
  } catch (e) {
    process.stderr.write(`preflight failed: ${e.message}\n`);
    shutdown(2, `preflight failed: ${e.message}`);
  }
  heartbeat();
  setInterval(heartbeat, HEARTBEAT_MS);
  const w = fs.watch(DIR, () => kick());
  w.on('error', (e) => shutdown(1, `watch failed: ${e.message}`));
  log(`armed pid=${process.pid} dir=${DIR}`);
  process.stdout.write(`armed: pid ${process.pid}, watching ${DIR}\n`);
  drain();
}

main().catch((e) => shutdown(1, e.stack || e.message));
