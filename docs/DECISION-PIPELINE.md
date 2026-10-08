# Decision pipeline

## 1. Typed intake

The caller supplies a complete `Request`. Absence is data, not an omitted field:
use `none` or `unknown` with an explanation. Stable IDs connect observations,
conditions, actions, response cases, and success criteria.

## 2. Deterministic compilation

The compiler removes actions that are forbidden, approval-gated, targeted at a
different entity, unknown in effect, missing a resolvable response case, or
blocked by a declared condition. No model can restore a removed action.

The canonical JSON and its SHA-256 commitment are retained for request binding.

## 3. Jev admission

Jev sees the normalized request and the remaining candidate IDs. It answers one
bounded choice: `ready` or `reject`. Provider errors and rejection both stop the
request before the payment boundary.

Jev does not select the final action and its confidence is not transformed into
a synthetic guarantee.

## 4. GPT-5.4 planning

After payment verification, GPT-5.4 returns a typed `DecisionIR`:

- one declared `action_id`;
- evidence IDs for the objective target;
- every applicable authority/constraint reference;
- every success-criterion ID; and
- an optional, code-verifiable declared-cost comparison.

The IR cannot contain a new tool, parameter, goal, source, or free-form command.

## 5. Deterministic IR checks

Code verifies admissibility, uniqueness, target binding, full goal and constraint
coverage, effect/reason compatibility, and numerical cost comparisons.

## 6. Semantic review

GPT-5.4 returns exactly four verdicts:

- `action_fit`;
- `evidence_relevance`;
- `constraint_alignment`; and
- `goal_alignment`.

Every verdict must be `supported`. `unsupported`, `uncertain`, missing, or
duplicate claims fail closed.

## 7. Trusted source binding

The model cannot choose its citations. Code derives the exact source set for
each claim and stores a hash binding. Rendering recomputes every hash, so a
decision cannot be replayed against changed input.

## 8. Deterministic rendering

The result exposes the selected declared action, fixed parameters, target,
effect, success contract, and response-case outcomes. It explicitly says that
ResolveSignal did not execute the business action and did not independently
verify the caller's evidence.

Any failure from stage 4 onward is a paid quality failure: no draft is returned
and the workflow requests a refund.
