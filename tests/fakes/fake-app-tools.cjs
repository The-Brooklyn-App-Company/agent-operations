// fake-app-tools.cjs - stands in for the desktop app's codex-app-tools MCP
// server in tests (stdio JSON-RPC). Never talks to an app or a model.
//
// Every tools/call is appended to $FAKE_APP_LOG as one JSON line. A thread
// is busy while the file $FAKE_APP_BUSY_DIR/<thread> exists. FAKE_APP_MODE:
//   ok (default)  every call succeeds
//   senderror     send_message_to_thread returns isError
//   nolist        tools/list lacks send_message_to_thread
//   die-on-send   exit (pipe closed) at the first send
//   hang-on-send  never answer a send (the caller times out)
//   rpcerror-on-send  answer a send with a JSON-RPC internal error
//   nostatus      read_thread answers with no turn status
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const mode = process.env.FAKE_APP_MODE || 'ok';
const logf = process.env.FAKE_APP_LOG || '/dev/null';
const busyDir = process.env.FAKE_APP_BUSY_DIR || '';
const reply = (id, result) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`);
const text = (o, isError = false) => ({ content: [{ type: 'text', text: JSON.stringify(o) }], isError });

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let m;
  try { m = JSON.parse(line); } catch (_) { return; }
  if (m.id === undefined) return;
  if (m.method === 'initialize') return reply(m.id, { protocolVersion: '2025-06-18', capabilities: {}, serverInfo: { name: 'fake' } });
  if (m.method === 'tools/list') {
    const tools = [{ name: 'read_thread' }];
    if (mode !== 'nolist') tools.push({ name: 'send_message_to_thread' });
    return reply(m.id, { tools });
  }
  if (m.method !== 'tools/call') return reply(m.id, {});
  const { name, arguments: a } = m.params;
  fs.appendFileSync(logf, `${JSON.stringify({ t: Date.now(), name, args: a })}\n`);
  if (name === 'read_thread') {
    if (mode === 'nostatus') return reply(m.id, text({ thread: { id: a.threadId } }));
    const busy = busyDir && fs.existsSync(path.join(busyDir, a.threadId));
    return reply(m.id, text({ thread: { id: a.threadId }, turns: [{ id: 't1', status: busy ? 'inProgress' : 'completed' }] }));
  }
  if (name === 'send_message_to_thread') {
    if (mode === 'die-on-send') process.exit(0);
    if (mode === 'hang-on-send') return;
    if (mode === 'rpcerror-on-send') return process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: m.id, error: { code: -32603, message: 'internal' } })}\n`);
    if (mode === 'senderror') return reply(m.id, text({ error: 'thread not found' }, true));
    return reply(m.id, text({ threadId: a.threadId }));
  }
  return reply(m.id, text({ error: 'unknown tool' }, true));
});
