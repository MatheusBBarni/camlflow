import { spawnCamlFlowClient } from "../dist";
import { makeProviderHooksEffectHandler, repoRoot } from "./shared";

const program = {
  path: "examples/provider-hooks/workflow.cml",
  includePaths: [],
  skillsDir: "examples/provider-hooks/skills",
};

async function main(): Promise<void> {
  const client = spawnCamlFlowClient({
    command: "dune",
    args: ["exec", "./bin/main.exe", "--", "serve", "--stdio"],
    cwd: repoRoot,
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
  });

  try {
    const initialize = await client.initialize();
    console.log("initialize:", JSON.stringify(initialize, null, 2));

    const compile = await client.compile({ program, entry: "main" });
    console.log(
      "compile:",
      JSON.stringify(
        {
          irVersion: compile.irVersion,
          artifactVersion:
            compile.artifact && typeof compile.artifact === "object"
              ? (compile.artifact as { version?: string }).version ?? null
              : null,
        },
        null,
        2,
      ),
    );

    const result = await client.run({
      program,
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
