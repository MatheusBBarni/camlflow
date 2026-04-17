const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  JsonRpcRequestCancelledError,
  effectOutput,
  spawnCamlFlowClient,
} = require('../dist');

const repoRoot = path.resolve(__dirname, '..', '..', '..');

function makeEffectHandler() {
  return async ({ effect }) => {
    const input =
      typeof effect.input === 'object' && effect.input !== null ? effect.input : {};

    switch (`${effect.kind}:${effect.name}`) {
      case 'bound-agent:greeter':
        return effectOutput(`hello ${input.name ?? 'friend'}`);
      case 'local-prompt-skill:caveman':
        return effectOutput(String(input.prompt ?? '').replace(/^hello\s+/i, 'me '));
      case 'inline-agent:reviewer':
        return effectOutput('inline-review');
      default:
        return effectOutput('');
    }
  };
}

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

test('sdk smoke test covers initialize, compile, run, and progress', { timeout: 30000 }, async () => {
  const progress = [];
  const client = spawnCamlFlowClient({
    command: 'dune',
    args: ['exec', './bin/main.exe', '--', 'serve', '--stdio'],
    cwd: repoRoot,
    effectHandler: makeEffectHandler(),
    onProgress: async (notification) => {
      progress.push(notification);
    },
  });

  try {
    const initialize = await client.initialize();
    assert.equal(initialize.protocolVersion, '0.1.0');
    assert.equal(initialize.irVersion, '0.1.0');
    assert.equal(initialize.capabilities.trace, true);
    assert.equal(initialize.capabilities.diagnostic, true);
    assert.equal(initialize.capabilities.progress, true);
    assert.equal(initialize.capabilities.streaming, false);

    const compile = await client.compile({
      program: {
        path: 'examples/basic/main.cml',
        includePaths: [],
        skillsDir: null,
      },
    });
    assert.equal(compile.irVersion, '0.1.0');
    assert.equal(compile.artifact.version, '0.1.0');

    const run = await client.run({
      program: {
        path: 'examples/provider-hooks/workflow.cml',
        includePaths: [],
        skillsDir: 'examples/provider-hooks/skills',
      },
      entry: 'main',
      input: 'Ada',
    });

    assert.equal(run.stepsRun, 3);
    assert.equal(run.output, 'inline-review');
    assert.ok(progress.some((entry) => entry.stage === 'run-start'));
    assert.ok(progress.some((entry) => entry.stage === 'effect-start'));
    assert.ok(progress.some((entry) => entry.stage === 'effect-finish'));
    assert.ok(progress.some((entry) => entry.stage === 'run-finish'));
  } finally {
    await client.shutdownAndExit();
  }
});

test('json-rpc host example still runs end-to-end', { timeout: 30000 }, async () => {
  const result = await runProcess('node', ['examples/json-rpc-host/host.js'], {
    cwd: repoRoot,
  });

  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /"protocolVersion":\s*"0\.1\.0"/);
  assert.match(result.stdout, /"irVersion":\s*"0\.1\.0"/);
  assert.match(result.stdout, /"output":\s*"inline-review"/);
});

test('json-rpc problem-coach host example still runs end-to-end', { timeout: 30000 }, async () => {
  const result = await runProcess('node', ['examples/json-rpc-problem-coach/host.js'], {
    cwd: repoRoot,
  });

  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /"stepsRun":\s*4/);
  assert.match(result.stdout, /"title":\s*"two sum solution pack"/);
});

test('sdk initialize can disable progress while keeping trace', { timeout: 30000 }, async () => {
  const traces = [];
  const progress = [];
  const client = spawnCamlFlowClient({
    command: 'dune',
    args: ['exec', './bin/main.exe', '--', 'serve', '--stdio'],
    cwd: repoRoot,
    effectHandler: makeEffectHandler(),
    onTrace: async (trace) => {
      traces.push(trace);
    },
    onProgress: async (notification) => {
      progress.push(notification);
    },
  });

  try {
    await client.initialize({
      notifications: {
        trace: true,
        progress: false,
      },
    });

    const result = await client.run({
      program: {
        path: 'examples/provider-hooks/workflow.cml',
        includePaths: [],
        skillsDir: 'examples/provider-hooks/skills',
      },
      entry: 'main',
      input: 'Ada',
    });

    assert.equal(result.output, 'inline-review');
    assert.ok(traces.some((entry) => entry.event === 'run-start'));
    assert.equal(progress.length, 0);
  } finally {
    await client.shutdownAndExit();
  }
});

test('sdk can cancel a run with AbortSignal', { timeout: 30000 }, async () => {
  const traces = [];
  const progress = [];
  let effectStartedResolve;
  const effectStarted = new Promise((resolve) => {
    effectStartedResolve = resolve;
  });

  const client = spawnCamlFlowClient({
    command: 'dune',
    args: ['exec', './bin/main.exe', '--', 'serve', '--stdio'],
    cwd: repoRoot,
    effectHandler: async ({ effect }) => {
      if (`${effect.kind}:${effect.name}` === 'bound-agent:greeter') {
        effectStartedResolve();
        await new Promise((resolve) => setTimeout(resolve, 250));
        return effectOutput(`hello ${effect.input?.name ?? 'friend'}`);
      }
      return effectOutput('');
    },
    onTrace: async (trace) => {
      traces.push(trace);
    },
    onProgress: async (notification) => {
      progress.push(notification);
    },
  });

  try {
    const initialize = await client.initialize();
    assert.equal(initialize.capabilities.cancelRequest, true);

    const controller = new AbortController();
    const runPromise = client.run(
      {
        program: {
          path: 'examples/basic/main.cml',
          includePaths: [],
          skillsDir: null,
        },
        entry: 'main',
        input: 'Ada',
      },
      { signal: controller.signal },
    );

    await effectStarted;
    controller.abort();

    await assert.rejects(runPromise, (error) => {
      assert.ok(error instanceof JsonRpcRequestCancelledError);
      assert.equal(error.method, 'camlflow/run');
      return true;
    });

    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.ok(
      traces.some((trace) => trace.event === 'run-cancelled'),
      `expected run-cancelled trace, got ${JSON.stringify(traces)}`,
    );
    assert.ok(
      progress.some((entry) => entry.stage === 'run-cancelled'),
      `expected run-cancelled progress, got ${JSON.stringify(progress)}`,
    );

    await assert.rejects(
      client.request('camlflow/run', {
        program: {
          path: 'examples/basic/main.cml',
          includePaths: [],
          skillsDir: null,
        },
        entry: 'main',
        input: 'Ada',
      }, { signal: AbortSignal.abort() }),
      (error) => {
        assert.ok(error instanceof JsonRpcRequestCancelledError);
        return true;
      },
    );
  } finally {
    await client.shutdownAndExit();
  }
});

test('sdk can cancel a pure-compute run after run-start', { timeout: 30000 }, async () => {
  const progress = [];
  let runStartedResolve;
  const runStarted = new Promise((resolve) => {
    runStartedResolve = resolve;
  });

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'camlflow-pure-cancel-'));
  const workflowPath = path.join(tempDir, 'main.cml');
  fs.writeFileSync(
    workflowPath,
    [
      'let rec fib (n : int) : int =',
      '  if n <= 1 then n else fib (n - 1) + fib (n - 2)',
      '',
      'let main (n : int) : int =',
      '  fib n',
      '',
    ].join('\n'),
    'utf8',
  );

  const client = spawnCamlFlowClient({
    command: 'dune',
    args: ['exec', './bin/main.exe', '--', 'serve', '--stdio'],
    cwd: repoRoot,
    onProgress: async (notification) => {
      progress.push(notification);
      if (notification.stage === 'run-start') {
        runStartedResolve();
      }
    },
  });

  try {
    await client.initialize();

    const controller = new AbortController();
    const runPromise = client.run(
      {
        program: {
          path: workflowPath,
          includePaths: [],
          skillsDir: null,
        },
        entry: 'main',
        input: 36,
      },
      { signal: controller.signal },
    );

    await runStarted;
    controller.abort();

    await assert.rejects(runPromise, (error) => {
      assert.ok(error instanceof JsonRpcRequestCancelledError);
      assert.equal(error.method, 'camlflow/run');
      return true;
    });

    await new Promise((resolve) => setTimeout(resolve, 150));

    assert.ok(
      progress.some((entry) => entry.stage === 'run-cancelled'),
      `expected run-cancelled progress, got ${JSON.stringify(progress)}`,
    );
  } finally {
    await client.shutdownAndExit();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
