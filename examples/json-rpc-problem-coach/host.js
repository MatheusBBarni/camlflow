#!/usr/bin/env node

const { spawn } = require('node:child_process');
const fs = require('node:fs');
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
  send({ jsonrpc: '2.0', id, method, params });
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
    if (!lengthHeader) throw new Error(`Missing Content-Length header: ${headerText}`);
    const length = Number(lengthHeader.split(':')[1].trim());
    const bodyStart = marker + 4;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return;
    const payload = buffer.slice(bodyStart, bodyEnd).toString('utf8');
    buffer = buffer.slice(bodyEnd);
    handleMessage(JSON.parse(payload));
  }
}

function renderCode(language) {
  switch (language) {
    case 'TypeScript':
      return [
        'function twoSum(nums: number[], target: number): number[] {',
        '  const seen = new Map<number, number>();',
        '  for (let i = 0; i < nums.length; i += 1) {',
        '    const need = target - nums[i];',
        '    if (seen.has(need)) return [seen.get(need)!, i];',
        '    seen.set(nums[i], i);',
        '  }',
        '  return [];',
        '}',
      ].join('\n');
    case 'OCaml':
      return [
        'let two_sum nums target =',
        '  let seen = Hashtbl.create (List.length nums) in',
        '  let rec loop index = function',
        '    | [] -> []',
        '    | value :: rest ->',
        '        let need = target - value in',
        '        match Hashtbl.find_opt seen need with',
        '        | Some prior -> [ prior; index ]',
        '        | None ->',
        '            Hashtbl.replace seen value index;',
        '            loop (index + 1) rest',
        '  in',
        '  loop 0 nums',
      ].join('\n');
    case 'Python':
    default:
      return [
        'def two_sum(nums, target):',
        '    seen = {}',
        '    for i, value in enumerate(nums):',
        '        need = target - value',
        '        if need in seen:',
        '            return [seen[need], i]',
        '        seen[value] = i',
        '    return []',
      ].join('\n');
  }
}

function handleEffect(message) {
  const effect = message.params.effect;
  const input = effect.input || {};
  let output;
  switch (`${effect.kind}:${effect.name}`) {
    case 'local-prompt-skill:caveman':
      output = `me solve ${String(input.prompt || '').split('Problem: ')[1] || 'problem'}`;
      break;
    case 'bound-skill:edge-case-planner':
      output = [
        'duplicate values where the second number closes the pair',
        'negative numbers and zero target combinations',
        'no valid pair when the contract allows an empty result',
      ];
      break;
    case 'bound-agent:draft-solver': {
      const request = input.request || {};
      output = {
        core_idea: 'Use a hash map from seen value to index while scanning once.',
        explanation:
          `Scan the array once. For each value, compute the complement and check whether it was seen earlier. ` +
          `This keeps the solution linear and works well for ${request.audience_label || 'the user'} use.`,
        code: renderCode(request.language_label || 'Python'),
        complexity: 'Time O(n), space O(n)',
      };
      break;
    }
    case 'inline-agent:answer_packager': {
      const request = input.request || {};
      const draft = input.draft || {};
      const edgeCases = input.edge_cases || [];
      output = {
        title: `${request.problem_name || 'Problem'} solution pack`,
        answer:
          `${draft.core_idea || 'Use a hash map.'} ` +
          `Keep a map of seen numbers to indices and return as soon as the complement appears.`,
        code: draft.code || renderCode(request.language_label || 'Python'),
        complexity: draft.complexity || 'Time O(n), space O(n)',
        edge_cases: edgeCases,
        pitfalls: [
          'Do not reuse the same index twice.',
          'Handle duplicate values by checking the complement before overwriting the map.',
        ],
        next_steps: [
          'Practice the sorted two-pointer variant.',
          'Explain why the hash map makes the lookup constant time on average.',
        ],
      };
      break;
    }
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
  if (!id || !pending.has(id)) return;
  const { resolve, reject } = pending.get(id);
  pending.delete(id);
  if (message.error) reject(new Error(`${message.error.code}: ${message.error.message}`));
  else resolve(message.result);
}

child.stdout.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  parseMessages();
});

child.on('exit', (code) => {
  if (code !== 0) process.exitCode = code;
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
  const input = JSON.parse(
    fs.readFileSync(path.join(projectRoot, 'examples/problem-coach/input.json'), 'utf8')
  );

  const init = await sendRequest('initialize', {});
  console.log('initialize:', JSON.stringify(init, null, 2));

  const result = await sendRequest('camlflow/run', {
    program: {
      path: 'examples/problem-coach/main.cml',
      includePaths: [],
      skillsDir: 'examples/problem-coach/skills',
    },
    entry: 'main',
    input,
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
