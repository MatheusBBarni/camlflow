#!/usr/bin/env node

const { spawn } = require('node:child_process');
const path = require('node:path');

const projectRoot = path.resolve(__dirname, '..', '..');
const child = spawn('dune', ['exec', './bin/main.exe', '--', 'serve', '--stdio'], {
  cwd: projectRoot,
  stdio: ['pipe', 'pipe', 'inherit'],
});

let nextId = 1;
const pending = new Map();
let buffer = Buffer.alloc(0);

function encodeMessage(message) {
  const payload = Buffer.from(JSON.stringify(message), 'utf8');
  const header = Buffer.from(`Content-Length: ${payload.length}\r\n\r\n`, 'utf8');
  return Buffer.concat([header, payload]);
}

function send(message) {
  child.stdin.write(encodeMessage(message));
}

function sendRequest(method, params) {
  const id = nextId++;
  const message = { jsonrpc: '2.0', id, method, params };
  send(message);
  return new Promise((resolve, reject) => {
    pending.set(String(id), { resolve, reject });
  });
}

function sendNotification(method, params) {
  send({ jsonrpc: '2.0', method, params });
}

function sendResponse(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function parseMessages() {
  while (true) {
    const marker = buffer.indexOf('\r\n\r\n');
    if (marker === -1) return;
    const headerText = buffer.slice(0, marker).toString('utf8');
    const headers = headerText.split('\r\n');
    const lengthHeader = headers.find((header) =>
      header.toLowerCase().startsWith('content-length:')
    );
    if (!lengthHeader) {
      throw new Error(`Missing Content-Length header: ${headerText}`);
    }
    const length = Number(lengthHeader.split(':')[1].trim());
    const bodyStart = marker + 4;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return;
    const payload = buffer.slice(bodyStart, bodyEnd).toString('utf8');
    buffer = buffer.slice(bodyEnd);
    handleMessage(JSON.parse(payload));
  }
}

function handleEffect(message) {
  const effect = message.params.effect;
  const input = effect.input || {};
  let output;
  switch (`${effect.kind}:${effect.name}`) {
    case 'bound-agent:greeter':
      output = `hello ${input.name || 'friend'}`;
      break;
    case 'local-prompt-skill:caveman':
      output = String(input.prompt || '').replace(/^hello\s+/i, 'me ');
      break;
    case 'inline-agent:reviewer':
      output = 'inline-review';
      break;
    default:
      output = '';
      break;
  }
  sendResponse(message.id, { output });
}

function handleMessage(message) {
  if (message.method === 'camlflow/executeEffect') {
    handleEffect(message);
    return;
  }

  if (message.method === 'camlflow/trace') {
    console.log('trace:', JSON.stringify(message.params));
    return;
  }

  if (message.method === 'camlflow/diagnostic') {
    console.log('diagnostic:', JSON.stringify(message.params));
    return;
  }

  const id = message.id == null ? null : String(message.id);
  if (!id || !pending.has(id)) {
    return;
  }

  const { resolve, reject } = pending.get(id);
  pending.delete(id);
  if (message.error) {
    reject(new Error(`${message.error.code}: ${message.error.message}`));
  } else {
    resolve(message.result);
  }
}

child.stdout.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  parseMessages();
});

child.on('exit', (code) => {
  if (code !== 0) {
    process.exitCode = code;
  }
});

function waitForExit() {
  return new Promise((resolve) => {
    let settled = false;
    let timer = null;
    const finish = () => {
      if (settled) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      resolve();
    };
    if (child.exitCode !== null) {
      finish();
      return;
    }
    timer = setTimeout(() => child.kill('SIGKILL'), 1000);
    child.once('exit', finish);
    child.once('close', finish);
  });
}

(async () => {
  const init = await sendRequest('initialize', {});
  console.log('initialize:', JSON.stringify(init, null, 2));

  const result = await sendRequest('camlflow/run', {
    program: {
      path: 'examples/provider-hooks/workflow.cml',
      includePaths: [],
      skillsDir: 'examples/provider-hooks/skills',
    },
    entry: 'main',
    input: 'Ada',
  });

  console.log('run:', JSON.stringify(result, null, 2));

  await sendRequest('shutdown', {});
  sendNotification('exit', {});
  child.stdin.end();
  await waitForExit();
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
  child.kill();
});
