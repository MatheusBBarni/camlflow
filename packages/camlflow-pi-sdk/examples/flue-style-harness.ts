import {
  createPiCamlFlowHarness,
  type JsonValue,
  type PiCamlFlowRuntime,
  type PiCamlFlowSandboxInput,
  type PiCamlFlowShellResult,
  type PiCamlFlowWorkflowRunResult,
} from "../dist/index.js";

export interface IssueTriagePayload {
  issueNumber: number;
  task: string;
}

export interface IssueTriageResult {
  triage: JsonValue;
  comment: string;
  shell: PiCamlFlowShellResult;
  workflow: PiCamlFlowWorkflowRunResult;
}

export const ephemeralSandboxWithDisposeExample = {
  kind: "ephemeral",
  dispose: async () => undefined,
} satisfies PiCamlFlowSandboxInput;

export async function runIssueTriageHarness(
  runtime: PiCamlFlowRuntime,
  payload: IssueTriagePayload,
  env: { GITHUB_TOKEN?: string },
): Promise<IssueTriageResult> {
  const harness = createPiCamlFlowHarness({ runtime });
  const agent = await harness.init({
    id: `issue-${payload.issueNumber}`,
    sandbox: "local",
    model: runtime.session.model,
  });
  const session = await agent.session("triage");

  try {
    const findings = await session.task("Inspect the checkout for likely triage risk areas.", {
      result: "json",
    });
    const triage = await session.skill("triage", {
      args: {
        issueNumber: payload.issueNumber,
        task: payload.task,
        findings,
      },
      result: "json",
    });
    const comment = await session.prompt(
      "Write a concise GitHub issue comment for the triage result.",
    );
    const shell = await session.shell("gh issue comment \"$ISSUE\" --body-file -", {
      stdin: comment,
      env: {
        GITHUB_TOKEN: env.GITHUB_TOKEN,
        ISSUE: String(payload.issueNumber),
      },
    });
    const workflow = await agent.runWorkflow({
      workflowPath: "examples/orchestrator-session/main.cml",
      input: {
        issue_number: payload.issueNumber,
        task: payload.task,
        goals: ["produce a concrete triage report"],
      },
    });

    return { triage, comment, shell, workflow };
  } finally {
    await session.close();
    await agent.close();
  }
}
