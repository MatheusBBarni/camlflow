const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

const packageRoot = path.resolve(__dirname, '..');

function runProcess(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let settled = false;
    const timeoutMs = options.timeoutMs ?? 30000;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      reject(new Error(`Timed out running ${command} ${args.join(' ')}`));
    }, timeoutMs);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });

    child.once('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });

    child.once('close', (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

test('sdk provider-hooks example runs end-to-end', { timeout: 30000 }, async () => {
  const result = await runProcess('node', ['examples-dist/provider-hooks.js'], {
    cwd: packageRoot,
  });

  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /"protocolVersion":\s*"0\.1\.0"/);
  assert.match(result.stdout, /"artifactVersion":\s*"0\.1\.0"/);
  assert.match(result.stdout, /"output":\s*"inline-review"/);
});

test('sdk attach-streams example runs end-to-end', { timeout: 30000 }, async () => {
  const result = await runProcess('node', ['examples-dist/attach-streams.js'], {
    cwd: packageRoot,
  });

  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /"protocolVersion":\s*"0\.1\.0"/);
  assert.match(result.stdout, /"output":\s*"inline-review"/);
});

test('sdk orchestrator workflow example runs end-to-end', { timeout: 30000 }, async () => {
  const result = await runProcess('node', ['examples-dist/orchestrator-session.js'], {
    cwd: packageRoot,
  });

  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /"stepsRun":\s*2/);
  assert.match(result.stdout, /"summary":\s*"Plan the work around the \.cml contract and host sandbox policy\."/);
});

test('sdk cancellation example exits cleanly after aborting a run', { timeout: 30000 }, async () => {
  const result = await runProcess('node', ['examples-dist/cancellation.js'], {
    cwd: packageRoot,
  });

  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /"cancelRequest":\s*true/);
  assert.match(result.stdout, /"progress":\s*true/);
  assert.match(result.stdout, /run-cancelled/);
  assert.match(result.stdout, /cancelled:/);
});
