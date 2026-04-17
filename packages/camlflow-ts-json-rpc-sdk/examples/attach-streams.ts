import { spawn } from "node:child_process";

import { CamlFlowJsonRpcClient } from "../dist";
import { makeProviderHooksEffectHandler, repoRoot } from "./shared";

async function main(): Promise<void> {
  const child = spawn("dune", ["exec", "./bin/main.exe", "--", "serve", "--stdio"], {
    cwd: repoRoot,
    stdio: ["pipe", "pipe", "inherit"],
  });

  if (child.stdin === null || child.stdout === null) {
    throw new Error("Failed to create stdio pipes for CamlFlow child process");
  }

  const client = new CamlFlowJsonRpcClient(
    {
      readable: child.stdout,
      writable: child.stdin,
      effectHandler: makeProviderHooksEffectHandler(),
      onTrace: async (trace) => {
        console.log("trace:", JSON.stringify(trace));
      },
      onDiagnostic: async (diagnostic) => {
        console.error("diagnostic:", JSON.stringify(diagnostic));
      },
      onProgress: async (progress) => {
        console.log("progress:", JSON.stringify(progress));
      },
      onOutputChunk: async (chunk) => {
        console.log("outputChunk:", JSON.stringify(chunk));
      },
    },
    { child },
  );

  try {
    const initialize = await client.initialize();
    console.log("initialize:", JSON.stringify(initialize, null, 2));

    const result = await client.run({
      program: {
        path: "examples/provider-hooks/workflow.cml",
        includePaths: [],
        skillsDir: "examples/provider-hooks/skills",
      },
      entry: "main",
      input: "Ada",
    });
    console.log("run:", JSON.stringify(result, null, 2));
  } finally {
    await client.shutdownAndExit();
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
