import {
  createPiCamlFlowHostSession,
  type JsonValue,
  type PiCamlFlowRuntime,
  type PiCamlFlowWorkflowRunResult,
} from "../dist/index.js";

export interface CamlFlowCommandRunRequest {
  workflowPath: string;
  entrypoint?: string;
  input?: JsonValue | null;
  skillsDir?: string | null;
  includePaths?: string[];
  signal?: AbortSignal;
}

export interface CamlFlowCommandUi {
  appendOutput(text: string): void | Promise<void>;
  showProgress(message: string): void | Promise<void>;
  showDiagnostic(message: string): void | Promise<void>;
  showResult(result: PiCamlFlowWorkflowRunResult): void | Promise<void>;
}

export interface CamlFlowCommandRunnerOptions {
  runtime: PiCamlFlowRuntime;
  ui: CamlFlowCommandUi;
  camlflowCommand?: string;
  camlflowArgs?: string[];
}

export function createCamlFlowCommandRunner(options: CamlFlowCommandRunnerOptions) {
  return async (request: CamlFlowCommandRunRequest): Promise<PiCamlFlowWorkflowRunResult> => {
    const camlflow = {
      ...(options.camlflowCommand ? { command: options.camlflowCommand } : {}),
      ...(options.camlflowArgs ? { args: options.camlflowArgs } : {}),
    };
    const host = createPiCamlFlowHostSession({
      runtime: options.runtime,
      camlflow,
      onProgress: async (progress) => {
        await options.ui.showProgress(textOrFallback(progress.message, progress.stage));
      },
      onDiagnostic: async (diagnostic) => {
        await options.ui.showDiagnostic(textOrFallback(diagnostic.message, "diagnostic"));
      },
      onOutputChunk: async (chunk) => {
        if (!chunk.done && typeof chunk.delta === "string" && chunk.delta.length > 0) {
          await options.ui.appendOutput(chunk.delta);
        }
      },
    });

    try {
      const result = await host.runWorkflow({
        workflowPath: request.workflowPath,
        entrypoint: request.entrypoint,
        input: request.input,
        skillsDir: request.skillsDir,
        includePaths: request.includePaths,
        signal: request.signal,
      });
      await options.ui.showResult(result);
      return result;
    } finally {
      await host.close();
    }
  };
}

export async function runProblemCoachFromPiCommand(
  runtime: PiCamlFlowRuntime,
  ui: CamlFlowCommandUi,
  signal?: AbortSignal,
): Promise<PiCamlFlowWorkflowRunResult> {
  const runCamlFlow = createCamlFlowCommandRunner({
    runtime,
    ui,
    camlflowCommand: "opam",
    camlflowArgs: ["exec", "--", "dune", "exec", "camlflow", "--", "serve", "--stdio"],
  });

  return runCamlFlow({
    workflowPath: "examples/problem-coach/main.cml",
    entrypoint: "main",
    input: {
      problem_name: "two sum",
      language: { tag: "Python" },
      audience: { tag: "Interview" },
    },
    skillsDir: "examples/problem-coach/skills",
    signal,
  });
}

function textOrFallback(value: JsonValue | undefined, fallback: string): string {
  return typeof value === "string" ? value : fallback;
}
