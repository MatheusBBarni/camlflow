const fs = require('node:fs');
const path = require('node:path');

const { effectOutput } = require('../dist');

const packageRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(packageRoot, '..', '..');

function makeProviderHooksEffectHandler() {
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

function renderProblemCoachCode(language) {
  switch (language) {
    case 'TypeScript':
      return [
        'function twoSum(nums: number[], target: number): number[] {',
        '  const seen = new Map<number, number>();',
        '  for (let i = 0; i < nums.length; i += 1) {',
        '    const need = target - nums[i];',
        '    if (seen.has(need)) return [seen.get(need)!, i];',
        '    seen.set(nums[i], i);',
        '  }',
        '  return [];',
        '}',
      ].join('\n');
    case 'OCaml':
      return [
        'let two_sum nums target =',
        '  let seen = Hashtbl.create (List.length nums) in',
        '  let rec loop index = function',
        '    | [] -> []',
        '    | value :: rest ->',
        '        let need = target - value in',
        '        match Hashtbl.find_opt seen need with',
        '        | Some prior -> [ prior; index ]',
        '        | None ->',
        '            Hashtbl.replace seen value index;',
        '            loop (index + 1) rest',
        '  in',
        '  loop 0 nums',
      ].join('\n');
    case 'Python':
    default:
      return [
        'def two_sum(nums, target):',
        '    seen = {}',
        '    for i, value in enumerate(nums):',
        '        need = target - value',
        '        if need in seen:',
        '            return [seen[need], i]',
        '        seen[value] = i',
        '    return []',
      ].join('\n');
  }
}

function makeProblemCoachEffectHandler() {
  return async ({ effect }) => {
    const input =
      typeof effect.input === 'object' && effect.input !== null ? effect.input : {};

    switch (`${effect.kind}:${effect.name}`) {
      case 'local-prompt-skill:caveman':
        return effectOutput(
          `me solve ${String(input.prompt ?? '').split('Problem: ')[1] ?? 'problem'}`
        );
      case 'bound-skill:edge-case-planner':
        return effectOutput([
          'duplicate values where the second number closes the pair',
          'negative numbers and zero target combinations',
          'no valid pair when the contract allows an empty result',
        ]);
      case 'bound-agent:draft-solver': {
        const request = input.request ?? {};
        return effectOutput({
          core_idea: 'Use a hash map from seen value to index while scanning once.',
          explanation:
            `Scan the array once. For each value, compute the complement and check whether it was seen earlier. ` +
            `This keeps the solution linear and works well for ${request.audience_label ?? 'the user'} use.`,
          code: renderProblemCoachCode(request.language_label ?? 'Python'),
          complexity: 'Time O(n), space O(n)',
        });
      }
      case 'inline-agent:answer_packager': {
        const request = input.request ?? {};
        const draft = input.draft ?? {};
        const edgeCases = Array.isArray(input.edge_cases) ? input.edge_cases : [];
        return effectOutput({
          title: `${request.problem_name ?? 'Problem'} solution pack`,
          answer:
            `${draft.core_idea ?? 'Use a hash map.'} ` +
            'Keep a map of seen numbers to indices and return as soon as the complement appears.',
          code: draft.code ?? renderProblemCoachCode(request.language_label ?? 'Python'),
          complexity: draft.complexity ?? 'Time O(n), space O(n)',
          edge_cases: edgeCases,
          pitfalls: [
            'Do not reuse the same index twice.',
            'Handle duplicate values by checking the complement before overwriting the map.',
          ],
          next_steps: [
            'Practice the sorted two-pointer variant.',
            'Explain why the hash map makes the lookup constant time on average.',
          ],
        });
      }
      default:
        return effectOutput('');
    }
  };
}

function loadProblemCoachInput() {
  return JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'examples/problem-coach/input.json'), 'utf8')
  );
}

module.exports = {
  packageRoot,
  repoRoot,
  makeProviderHooksEffectHandler,
  makeProblemCoachEffectHandler,
  loadProblemCoachInput,
};
