// mailroom-codex-watcher.cjs - EXPERIMENTAL: the Codex side of the mailroom.
//
// Usage (from the Codex bridge chat's own command session, never detached;
// normally through `mailroom.sh arm-codex`):
//   <app's bundled node> mailroom-codex-watcher.cjs --dir RING_DIR --server SERVER_MJS
//
// It relies on an undocumented interface of the Codex desktop app: the
// bundled codex-app-tools MCP server (SERVER_MJS), which reaches the app over
// a pipe the app provides only to commands started inside one of its chats.
// So it dies when the app restarts and must be re-armed by the bridge chat.
//
// Before watching it opens the MCP connection and checks it: the tool list
// must have send_message_to_thread and read_thread, and read_thread on its
// own chat (CODEX_THREAD_ID, or --self-thread) must succeed. Then it watches
// RING_DIR (fs.watch, debounced) and handles waiting rings serially, oldest
// name first, including any already waiting at start:
//   <thread>--<label>--steer.md  sent at once (it may land mid-turn)
//   <thread>--<label>--queue.md  held until the target's latest turn is no
//                                longer running (checked every 5 s, only
//                                while a queue ring is held), then sent; a
//                                hold file in .watcher/holding/ tells the
//                                relay's sweep to wait. After 10 min it is
//                                released to the relay's direct queue.
//   echo--*                      health probes: filed, never sent
// A send is one send_message_to_thread call to the target thread with the
// text `Doorbell [<ring name>]: <ring body>` (the native tool has no mode:
// queue versus steer is decided here). Each handled ring moves to
// delivered/ with one line in delivered/log.tsv:
//   ISO-time <TAB> epoch <TAB> ring <TAB> watcher <TAB> mode <TAB> status
// mode is steer, queue (sent when idle), queue-unknown (the thread's state
// could not be read, so it was sent at once) or echo; status is ok, or
// unknown after a call timeout or a send cut off by a crash or a closed pipe
// (never re-sent automatically). Each ring is claimed into .watcher/sending/
// by an atomic rename before its send, so the relay's fallback cannot send
// it too. A ring whose send fails twice is left for the relay's fallbacks.
//
// Health: .watcher/heartbeat (ISO time and pid) every 60 s; .watcher/log.
// One watcher per RING_DIR (.watcher/pid). It exits non-zero, with a log
// line, when the app pipe closes or three sends in a row fail: no spinning.
//
// Exit codes: 0 stopped by a signal; 1 connection lost or repeated failure;
// 2 usage or preflight error; 3 another watcher is running.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const readline = require('node:readline');

const ms = (name, dflt) => {
  const v = Number(process.env[name]);
  return Number.isFinite(v) && v > 0 ? v : dflt;
};
// Overridable for tests only.
const HEARTBEAT_MS = ms('AO_MR_HEARTBEAT_MS', 60000);
const IDLE_POLL_MS = ms('AO_MR_IDLE_POLL_MS', 5000);
const HOLD_CAP_MS = ms('AO_MR_HOLD_CAP_MS', 600000);
const CALL_TIMEOUT_MS = ms('AO_MR_CALL_TIMEOUT_MS', 30000);
const DEBOUNCE_MS = 150;
const MAX_ERRORS_IN_A_ROW = 3;
const MAX_TRIES_PER_RING = 2;
const BUSY = /progress|running|active|started|pending/i;

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
const DELIVERED = path.join(DIR, 'delivered');
const PIDFILE = path.join(STATE, 'pid');

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
    await this.request('initialize', {
      protocolVersion: '2025-06-18', capabilities: {},
      clientInfo: { name: 'agent-operations-mailroom', version: '0.3.1' },
    });
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
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
let pollTimer = null;
let debounce = null;
const tries = new Map();
const released = new Set();

function shutdown(code, why) {
  log(`stopping (${code}): ${why}`);
  try { if (fs.readFileSync(PIDFILE, 'utf8').trim() === String(process.pid)) fs.unlinkSync(PIDFILE); } catch (_) { /* none */ }
  if (app) app.close();
  process.exit(code);
}

// takePidfile  Refuse while another live watcher's pid is recorded. Not a
// lock: `mailroom.sh arm-codex` holds the kernel lock that makes this the
// only watcher; this check only catches a second direct start.
function takePidfile() {
  try {
    const other = Number(fs.readFileSync(PIDFILE, 'utf8').trim());
    if (other && other !== process.pid) { process.kill(other, 0); return false; }
  } catch (_) { /* none, or dead */ }
  writeAtomic(PIDFILE, `${process.pid}\n`);
  return true;
}

function heartbeat() {
  try { writeAtomic(path.join(STATE, 'heartbeat'), `${iso()} ${process.pid}\n`); }
  catch (e) { log(`heartbeat failed: ${e.message}`); }
}

function waitingRings() {
  let names;
  try { names = fs.readdirSync(DIR); } catch (e) { shutdown(1, `cannot read ${DIR}: ${e.message}`); }
  return names.filter((n) => n.endsWith('.md') && !n.startsWith('.')
    && fs.statSync(path.join(DIR, n), { throwIfNoEntry: false })?.isFile()).sort();
}

function fileRing(name, mode, status, from = DIR) {
  fs.mkdirSync(DELIVERED, { recursive: true });
  try { fs.renameSync(path.join(from, name), path.join(DELIVERED, name)); }
  catch (e) { if (e.code === 'ENOENT') return false; throw e; }
  const now = new Date();
  fs.appendFileSync(path.join(DELIVERED, 'log.tsv'),
    `${now.toISOString()}\t${Math.floor(now.getTime() / 1000)}\t${name}\twatcher\t${mode}\t${status}\n`);
  dropHold(name);
  log(`filed ${name} mode=${mode} status=${status}`);
  return true;
}

function holdSince(name) {
  try { return Number(fs.readFileSync(path.join(HOLDS, name), 'utf8').trim()) * 1000; }
  catch (_) { return 0; }
}
function dropHold(name) {
  try { fs.unlinkSync(path.join(HOLDS, name)); } catch (_) { /* none */ }
}
// release NAME  Leave a ring to the relay's fallback for good: recorded in
// .watcher/released/ so a restarted watcher does not take it up again.
function release(name) {
  released.add(name);
  dropHold(name);
  try { fs.mkdirSync(RELEASED, { recursive: true }); fs.writeFileSync(path.join(RELEASED, name), ''); } catch (_) { /* best effort */ }
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

async function handle(name) {
  const file = path.join(DIR, name);
  if (name.startsWith('echo--')) { fileRing(name, 'echo', 'ok'); return; }
  const thread = name.split('--')[0];
  let mode = name.endsWith('--steer.md') ? 'steer' : 'queue';
  if (mode === 'queue') {
    const state = await threadState(thread);
    if (state === 'busy') {
      let since = holdSince(name);
      if (!since) {
        since = Date.now();
        fs.mkdirSync(HOLDS, { recursive: true });
        writeAtomic(path.join(HOLDS, name), `${Math.floor(since / 1000)}\n`);
        log(`holding ${name}: target busy`);
      }
      if (Date.now() - since >= HOLD_CAP_MS) {
        release(name);
        log(`queue-cap ${name}: target still busy; released to the relay's direct queue`);
      }
      return;
    }
    if (state === 'unknown') mode = 'queue-unknown';
  }
  // Claim the ring (an atomic rename) so the relay's fallback cannot send it
  // too; a ring someone else took is skipped.
  const claimed = path.join(SENDING, name);
  try { fs.renameSync(file, claimed); } catch (e) { if (e.code === 'ENOENT') { dropHold(name); return; } throw e; }
  const body = fs.readFileSync(claimed, 'utf8').trim();
  let res;
  try {
    res = await app.call('send_message_to_thread', { threadId: thread, hostId: 'local', prompt: `Doorbell [${name}]: ${body}` });
  } catch (e) {
    if (e instanceof Unknown) {
      // Never re-sent automatically: the message may have landed (K-28).
      fileRing(name, mode, 'unknown', SENDING);
      return;
    }
    if (app.closed) { fileRing(name, mode, 'unknown', SENDING); throw e; }
    res = { isError: true, content: [{ type: 'text', text: e.message }] };
  }
  if (res && !res.isError) {
    errorsInARow = 0;
    tries.delete(name);
    fileRing(name, mode, 'ok', SENDING);
    return;
  }
  // A clear refusal: put it back for the next try or the relay's fallback.
  try { fs.renameSync(claimed, file); } catch (e) { log(`cannot return ${name}: ${e.message}`); }
  errorsInARow++;
  const n = (tries.get(name) || 0) + 1;
  tries.set(name, n);
  const why = JSON.stringify(res && res.content).slice(0, 300);
  log(`send failed for ${name} (try ${n}): ${why}`);
  if (n >= MAX_TRIES_PER_RING) { release(name); log(`left ${name} for the relay's fallback`); }
  if (errorsInARow >= MAX_ERRORS_IN_A_ROW) shutdown(1, `${errorsInARow} sends in a row failed`);
}

async function drain() {
  if (draining) { again = true; return; }
  draining = true;
  try {
    do {
      again = false;
      for (const name of waitingRings()) {
        if (released.has(name)) continue;
        await handle(name);
      }
    } while (again);
  } catch (e) {
    shutdown(1, `delivery stopped: ${e.message}`);
  } finally {
    draining = false;
  }
  // Re-check held queue rings only while one is held.
  let held = [];
  try { held = fs.readdirSync(HOLDS).filter((n) => !n.includes('.tmp.')); } catch (_) { /* none */ }
  for (const n of held) if (!fs.existsSync(path.join(DIR, n))) dropHold(n);
  clearTimeout(pollTimer);
  if (held.some((n) => fs.existsSync(path.join(DIR, n)))) pollTimer = setTimeout(drain, IDLE_POLL_MS);
}

async function main() {
  if (!args.self) { process.stderr.write('no CODEX_THREAD_ID: run this from the bridge chat\'s own command session\n'); process.exit(2); }
  if (!fs.statSync(DIR, { throwIfNoEntry: false })?.isDirectory()) { process.stderr.write(`not a directory: ${DIR}\n`); process.exit(2); }
  if (!fs.existsSync(args.server)) { process.stderr.write(`server not found: ${args.server}\n`); process.exit(2); }
  fs.mkdirSync(HOLDS, { recursive: true });
  fs.mkdirSync(SENDING, { recursive: true });
  fs.mkdirSync(DELIVERED, { recursive: true });
  if (!takePidfile()) { process.stderr.write('another watcher is running for this folder\n'); process.exit(3); }
  // Holds keep their start time across restarts (the 10-minute cap is per
  // ring, not per watcher); releases stay released while the ring waits.
  fs.mkdirSync(RELEASED, { recursive: true });
  for (const f of fs.readdirSync(RELEASED)) {
    if (fs.existsSync(path.join(DIR, f))) released.add(f); else fs.unlinkSync(path.join(RELEASED, f));
  }
  for (const f of fs.readdirSync(HOLDS)) if (!fs.existsSync(path.join(DIR, f))) dropHold(f);
  // A send interrupted by a crash may have landed: filed as unknown, never re-sent.
  for (const f of fs.readdirSync(SENDING)) if (f.endsWith('.md')) fileRing(f, 'interrupted', 'unknown', SENDING);
  process.on('SIGTERM', () => shutdown(0, 'SIGTERM'));
  process.on('SIGINT', () => shutdown(0, 'SIGINT'));
  process.on('SIGHUP', () => shutdown(0, 'SIGHUP'));

  app = new AppTools(args.server);
  app.onLost = (e) => shutdown(1, `connection lost: ${e.message}`);
  try {
    await app.initialize();
    const list = await app.request('tools/list', {});
    const names = new Set(((list && list.tools) || []).map((t) => t.name));
    for (const t of ['send_message_to_thread', 'read_thread']) if (!names.has(t)) throw new Error(`tool ${t} missing`);
    const pre = await app.call('read_thread', { threadId: args.self, turnLimit: 1, includeOutputs: false, maxOutputCharsPerItem: 0 });
    if (!pre || pre.isError) throw new Error('read_thread preflight on the bridge chat failed');
  } catch (e) {
    process.stderr.write(`preflight failed: ${e.message}\n`);
    shutdown(2, `preflight failed: ${e.message}`);
  }
  heartbeat();
  setInterval(heartbeat, HEARTBEAT_MS);
  const w = fs.watch(DIR, () => { clearTimeout(debounce); debounce = setTimeout(drain, DEBOUNCE_MS); });
  w.on('error', (e) => shutdown(1, `watch failed: ${e.message}`));
  log(`armed pid=${process.pid} dir=${DIR}`);
  process.stdout.write(`armed: pid ${process.pid}, watching ${DIR}\n`);
  drain();
}

main().catch((e) => shutdown(1, e.stack || e.message));
