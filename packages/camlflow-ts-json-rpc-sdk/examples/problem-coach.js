#!/usr/bin/env node

const { spawnCamlFlowClient } = require('../dist');
const {
  loadProblemCoachInput,
  makeProblemCoachEffectHandler,
  repoRoot,
} = require('./shared');

async function main() {
  const client = spawnCamlFlowClient({
    command: 'dune',
    args: ['exec', './bin/main.exe', '--', 'serve', '--stdio'],
    cwd: repoRoot,
    effectHandler: makeProblemCoachEffectHandler(),
    onTrace: async (trace) => {
      console.log('trace:', JSON.stringify(trace));
    },
    onDiagnostic: async (diagnostic) => {
      console.error('diagnostic:', JSON.stringify(diagnostic));
    },
  });

  try {
    const initialize = await client.initialize();
    console.log('initialize:', JSON.stringify(initialize, null, 2));

    const result = await client.run({
      program: {
        path: 'examples/problem-coach/main.cml',
        includePaths: [],
        skillsDir: 'examples/problem-coach/skills',
      },
      entry: 'main',
      input: loadProblemCoachInput(),
    });
    console.log('run:', JSON.stringify(result, null, 2));
  } finally {
    await client.shutdownAndExit();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
