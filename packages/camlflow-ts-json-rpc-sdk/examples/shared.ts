import * as fs from "node:fs";
import * as path from "node:path";

import {
  effectOutput,
  type CamlFlowEffectHandler,
  type JsonObject,
  type JsonValue,
} from "../dist";

const packageRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(packageRoot, "..", "..");

type JsonRecord = Record<string, JsonValue | undefined>;

function isJsonRecord(value: JsonValue | undefined): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asJsonRecord(value: JsonValue | undefined): JsonRecord {
  return isJsonRecord(value) ? value : {};
}

function stringField(record: JsonRecord, field: string, fallback = ""): string {
  const value = record[field];
  return typeof value === "string" ? value : fallback;
}

function stringListField(record: JsonRecord, field: string): string[] {
  const value = record[field];
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

export { packageRoot, repoRoot };

async function* textDeltas(text: string): AsyncIterable<string> {
  if (text.length === 0) {
    return;
  }

  const midpoint = Math.max(1, Math.floor(text.length / 2));
  yield text.slice(0, midpoint);
  yield text.slice(midpoint);
}

export function makeProviderHooksEffectHandler(): CamlFlowEffectHandler {
  return async ({ effect }, _request, context) => {
    const input = asJsonRecord(effect.input);
    const relayTextOutput = async (text: string): Promise<string> =>
      context.relayTextOutput(textDeltas(text), {
        streamId: `provider-hooks-${context.step ?? 0}-${effect.name}`,
      });

    switch (`${effect.kind}:${effect.name}`) {
      case "bound-agent:greeter": {
        const output = `hello ${stringField(input, "name", "friend")}`;
        await relayTextOutput(output);
        return effectOutput(output);
      }
      case "local-prompt-skill:caveman": {
        const output = stringField(input, "prompt").replace(/^hello\s+/i, "me ");
        await relayTextOutput(output);
        return effectOutput(output);
      }
      case "inline-agent:reviewer": {
        const output = "inline-review";
        await relayTextOutput(output);
        return effectOutput(output);
      }
      default:
        return effectOutput("");
    }
  };
}

function renderProblemCoachCode(language: string): string {
  switch (language) {
    case "TypeScript":
      return [
        "function twoSum(nums: number[], target: number): number[] {",
        "  const seen = new Map<number, number>();",
        "  for (let i = 0; i < nums.length; i += 1) {",
        "    const need = target - nums[i];",
        "    if (seen.has(need)) return [seen.get(need)!, i];",
        "    seen.set(nums[i], i);",
        "  }",
        "  return [];",
        "}",
      ].join("\n");
    case "OCaml":
      return [
        "let two_sum nums target =",
        "  let seen = Hashtbl.create (List.length nums) in",
        "  let rec loop index = function",
        "    | [] -> []",
        "    | value :: rest ->",
        "        let need = target - value in",
        "        match Hashtbl.find_opt seen need with",
        "        | Some prior -> [ prior; index ]",
        "        | None ->",
        "            Hashtbl.replace seen value index;",
        "            loop (index + 1) rest",
        "  in",
        "  loop 0 nums",
      ].join("\n");
    case "Python":
    default:
      return [
        "def two_sum(nums, target):",
        "    seen = {}",
        "    for i, value in enumerate(nums):",
        "        need = target - value",
        "        if need in seen:",
        "            return [seen[need], i]",
        "        seen[value] = i",
        "    return []",
      ].join("\n");
  }
}

export function makeProblemCoachEffectHandler(): CamlFlowEffectHandler {
  return async ({ effect }) => {
    const input = asJsonRecord(effect.input);

    switch (`${effect.kind}:${effect.name}`) {
      case "local-prompt-skill:caveman": {
        const prompt = stringField(input, "prompt");
        const suffix = prompt.split("Problem: ")[1] ?? "problem";
        return effectOutput(`me solve ${suffix}`);
      }
      case "bound-skill:edge-case-planner":
        return effectOutput([
          "duplicate values where the second number closes the pair",
          "negative numbers and zero target combinations",
          "no valid pair when the contract allows an empty result",
        ]);
      case "bound-agent:draft-solver": {
        const request = asJsonRecord(input.request);
        const audienceLabel = stringField(request, "audience_label", "the user");
        const languageLabel = stringField(request, "language_label", "Python");
        return effectOutput({
          core_idea: "Use a hash map from seen value to index while scanning once.",
          explanation:
            "Scan the array once. For each value, compute the complement and check whether it was seen earlier. " +
            `This keeps the solution linear and works well for ${audienceLabel} use.`,
          code: renderProblemCoachCode(languageLabel),
          complexity: "Time O(n), space O(n)",
        });
      }
      case "inline-agent:answer_packager": {
        const request = asJsonRecord(input.request);
        const draft = asJsonRecord(input.draft);
        const edgeCases = stringListField(input, "edge_cases");
        const problemName = stringField(request, "problem_name", "Problem");
        const languageLabel = stringField(request, "language_label", "Python");
        return effectOutput({
          title: `${problemName} solution pack`,
          answer:
            `${stringField(draft, "core_idea", "Use a hash map.")} ` +
            "Keep a map of seen numbers to indices and return as soon as the complement appears.",
          code: stringField(draft, "code", renderProblemCoachCode(languageLabel)),
          complexity: stringField(draft, "complexity", "Time O(n), space O(n)"),
          edge_cases: edgeCases,
          pitfalls: [
            "Do not reuse the same index twice.",
            "Handle duplicate values by checking the complement before overwriting the map.",
          ],
          next_steps: [
            "Practice the sorted two-pointer variant.",
            "Explain why the hash map makes the lookup constant time on average.",
          ],
        });
      }
      case "inline-agent:repo_researcher":
      case "inline-agent:repo-researcher":
      case "bound-agent:repo-researcher":
        return effectOutput({
          summary: "Sandbox checkout needs focused triage before implementation.",
          risky_files: ["packages/camlflow-orchestrator/src/index.ts"],
          evidence: ["issue input requested a shared sandbox policy"],
        });
      case "bound-skill:triage":
        return effectOutput({
          summary: "Plan the work around the .cml contract and host sandbox policy.",
          next_steps: ["inspect the workflow", "choose sandbox policy", "run verification"],
          validation: ["type-check the workflow", "run the host smoke test"],
        });
      default:
        return effectOutput("");
    }
  };
}

export function loadProblemCoachInput(): JsonObject {
  return JSON.parse(
    fs.readFileSync(path.join(repoRoot, "examples/orchestrator-session/input.json"), "utf8"),
  ) as JsonObject;
}
