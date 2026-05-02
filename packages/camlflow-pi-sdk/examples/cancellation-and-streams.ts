import {
  createPiCamlFlowHostSession,
  type JsonValue,
  type PiCamlFlowHostSession,
  type PiCamlFlowRuntime,
  type PiCamlFlowWorkflowRunResult,
} from "../dist/index.js";

export interface WorkflowPanel {
  append(text: string): void | Promise<void>;
  setStatus(status: "idle" | "running" | "cancelled" | "failed" | "finished"): void | Promise<void>;
  setResult(result: PiCamlFlowWorkflowRunResult): void | Promise<void>;
  setError(error: Error): void | Promise<void>;
}

export interface WorkflowPanelRunOptions {
  workflowPath: string;
  entrypoint?: string;
  input?: JsonValue | null;
  skillsDir?: string | null;
  includePaths?: string[];
}

export function createCamlFlowWorkflowPanelController(runtime: PiCamlFlowRuntime, panel: WorkflowPanel) {
  let host: PiCamlFlowHostSession | undefined;
  let controller: AbortController | undefined;
  let activeRun: Promise<PiCamlFlowWorkflowRunResult> | undefined;

  return {
    async start(options: WorkflowPanelRunOptions): Promise<PiCamlFlowWorkflowRunResult> {
      if (activeRun) {
        throw new Error("A CamlFlow workflow is already running in this panel");
      }

      controller = new AbortController();
      host = createPiCamlFlowHostSession({
        runtime,
        onProgress: async (progress) => {
          await panel.setStatus(progress.stage === "run-finish" ? "finished" : "running");
        },
        onOutputChunk: async (chunk) => {
          if (!chunk.done && typeof chunk.delta === "string") {
            await panel.append(chunk.delta);
          }
        },
      });

      await panel.setStatus("running");
      activeRun = host.runWorkflow({
        workflowPath: options.workflowPath,
        entrypoint: options.entrypoint,
        input: options.input,
        skillsDir: options.skillsDir,
        includePaths: options.includePaths,
        signal: controller.signal,
      });

      try {
        const result = await activeRun;
        await panel.setResult(result);
        await panel.setStatus("finished");
        return result;
      } catch (error) {
        const normalized = error instanceof Error ? error : new Error(String(error));
        await panel.setStatus(controller.signal.aborted ? "cancelled" : "failed");
        await panel.setError(normalized);
        throw normalized;
      } finally {
        activeRun = undefined;
        controller = undefined;
        const completedHost = host;
        host = undefined;
        await completedHost.close();
      }
    },

    async cancel(): Promise<void> {
      controller?.abort();
      await host?.cancel();
      await panel.setStatus("cancelled");
    },
  };
}
