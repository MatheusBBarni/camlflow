import {
  JsonRpcRequestCancelledError,
  effectOutput,
  spawnCamlFlowClient,
} from "../dist";
import { repoRoot } from "./shared";

async function main(): Promise<void> {
  let effectStartedResolve: (() => void) | undefined;
  const effectStarted = new Promise<void>((resolve) => {
    effectStartedResolve = resolve;
  });

  const controller = new AbortController();
  const client = spawnCamlFlowClient({
    command: "dune",
    args: ["exec", "./bin/main.exe", "--", "serve", "--stdio"],
    cwd: repoRoot,
    effectHandler: async ({ effect }) => {
      if (`${effect.kind}:${effect.name}` === "bound-agent:greeter") {
        effectStartedResolve?.();
        await new Promise((resolve) => setTimeout(resolve, 250));
        const input =
          typeof effect.input === "object" && effect.input !== null ? effect.input : {};
        return effectOutput(`hello ${(input as { name?: string }).name ?? "friend"}`);
      }

      return effectOutput("");
    },
    onTrace: async (trace) => {
      console.log("trace:", JSON.stringify(trace));
    },
    onProgress: async (progress) => {
      console.log("progress:", JSON.stringify(progress));
    },
    onDiagnostic: async (diagnostic) => {
      console.error("diagnostic:", JSON.stringify(diagnostic));
    },
  });

  try {
    const initialize = await client.initialize();
    console.log(
      "initialize:",
      JSON.stringify(
        {
          protocolVersion: initialize.protocolVersion,
          irVersion: initialize.irVersion,
          cancelRequest: initialize.capabilities.cancelRequest,
          progress: initialize.capabilities.progress,
        },
        null,
        2,
      ),
    );

    const runPromise = client.run(
      {
        program: {
          path: "examples/provider-hooks/workflow.cml",
          includePaths: [],
          skillsDir: "examples/provider-hooks/skills",
        },
        entry: "main",
        input: "Ada",
      },
      { signal: controller.signal },
    );

    await effectStarted;
    controller.abort();

    try {
      await runPromise;
      throw new Error("expected cancellation, but run completed successfully");
    } catch (error) {
      if (error instanceof JsonRpcRequestCancelledError) {
        console.log(
          "cancelled:",
          JSON.stringify({ method: error.method, id: error.id }, null, 2),
        );
      } else {
        throw error;
      }
    }
  } finally {
    await client.shutdownAndExit();
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
