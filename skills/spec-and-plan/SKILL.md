---
name: spec-and-plan
description: Drive a project or a small change through spec -> outside review -> validated fold -> plan -> outside review -> validated fold, then on approval execute and run a /simplify pass over the resulting diff. Use when the user invokes /spec-and-plan or asks to design a feature with review gates before implementation. Requires the superpowers plugin.
---

# Spec and Plan

Produce a spec and an implementation plan, each subjected to an outside review
whose findings are validated before anything is folded in, then — only on
explicit approval — execute it and run one simplify/cleanup pass over the resulting
diff. Execution is a separate, deliberate decision; declining it leaves an
accepted plan as the terminal state.

## Dependency check (do this first)

This skill orchestrates `superpowers:brainstorming` and
`superpowers:writing-plans`. If the superpowers plugin is unavailable, emit
exactly this and stop — make no file changes:

```
/spec-and-plan requires the superpowers plugin, which isn't available here. Install superpowers, or use this harness's own planning flow.
```

Detect by attempting the skill invocation and treating failure as unsupported.
Do not sniff for harness identity; the dependency is what matters.

## Tiers

`superpowers:brainstorming` sizes work as a quick, clear task, a small change,
or a project with a written design. Scale the artifact, never the gate.

| Size | Artifacts | Gates | Reviewers |
|---|---|---|---|
| Quick task | none; just do it | none | — |
| Small change | one combined design+plan note on disk (~20-40 lines) | 1 | 1 |
| Project | spec, then plan | 2 (one each) | one installed target; more only with consent |

A quick task gets no gate: its result is the answer, and reviewing a plan for
cheap work costs more than doing it.

For a small change this **deliberately deviates** from
`superpowers:brainstorming`, which keeps a small change's design in chat and
writes no document. outside-voice reviews files; an in-chat design is
unreviewable. Say so out loud when it applies. If the work does not merit
writing ~30 lines, use `superpowers:brainstorming` directly instead.

"Provider-diverse" means diverse from the **caller**, not within the reviewer
set. The script does not pick models for you: choose a target whose provider
differs from the calling harness's. `kiro` runs its default model unless
`OUTSIDE_VOICE_MODEL` is set; set it to pick a model from a different provider.
One reviewer is meaningfully diverse.

## Flow

1. **Invoke `superpowers:brainstorming` once.** It sizes the work *and*
   carries it through to a design. Sizing and design are one
   invocation, not two — do not re-enter the skill for step 2.
2. **Ensure a reviewable artifact exists on disk.** outside-voice reviews files;
   there is nothing to gate otherwise.
   - *Project:* brainstorming has already written
     `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`. Use that path.
   - *Small change:* brainstorming stops at an in-chat design and writes no file, so
     **you** write the combined design+plan note yourself to
     `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, ~20-40 lines
     covering problem, approach, files touched, testing, and risks. Say out
     loud that this deviates from brainstorming's small-change path, and why.
   - *Quick task:* no artifact and no gate. Stop here.

   Run the inline self-review over the artifact before the gate — placeholders,
   internal consistency, scope, ambiguity. Do not reimplement that checklist;
   it is brainstorming's.
3. **Gate the artifact** (below). Run it to `accepted` before step 4.
4. **Plan** (project only). Invoke `superpowers:writing-plans`, then run
   its own self-review checklist (spec coverage, placeholders, name
   consistency).
5. **Gate the plan.** Same gate, second application.
6. **Execution checkpoint.** Report the accepted artifact paths and ask whether
   to execute. Proceed only on an explicit yes; otherwise stop here. Before
   executing, record the base: `git rev-parse HEAD`.
7. **Execute.**
   - *Project:* invoke `superpowers:subagent-driven-development`.
   - *Small change:* implement from the combined note via the normal TDD workflow.
8. **Simplify.** Run a simplify/cleanup pass (e.g. the harness's `/simplify`, if available) once, scoped to `<base-sha>..HEAD` plus the
   working tree — only code this execution produced. Then run the project's
   verification command.
9. **Accept.** Show the simplify diff and the verification output. If
   verification fails, report it with the output and do not commit; the user
   chooses fix or revert. On acceptance, commit the pass separately
   (`refactor: simplify …`) so it can be reverted on its own.

**Do not commit the spec or plan.** Suppress brainstorming's instruction to
commit the design document. Superpowers spec/plan files are not
to be committed, and in some repos `docs/` is gitignored so the commit would
fail or do nothing useful.

**Do not invoke the `/outside-voice` skill.** `brainstorming` permits only
`writing-plans` as a successor skill. Call the tool directly. Nothing is lost:
prompt framing, output framing, target validation, provider selection, and
timeouts all live in the script. The only behavior the outside-voice skill adds
is the multi-target confirmation dance, replicated in gate step 1.

## The gate

Apply once per written artifact.

1. **Dispatch.** `<skill-dir>` is the directory containing this `SKILL.md`.
   Propose one installed target, chosen from `outside-voice.sh`'s resolution,
   and ask before proposing several. Never take the expensive path without
   explicit consent, given either in the original request or as an answer to
   the ask; if you can't ask, show the preview and stop. Pass the artifact as
   an **exact file path** — a directory pathspec deliberately cannot reach
   gitignored files.

   Single target — dispatches immediately, no confirmation gate:
   ```bash
   bash <skill-dir>/scripts/outside-voice.sh <target> "<instruction>" <artifact-path>
   ```

   Multiple targets — a comma list with no spaces, or `all`. Run **without**
   `--yes` first; that prints the resolved target list and cost estimate and
   exits without dispatching. Show it, get explicit approval, then re-run with
   `--yes`:
   ```bash
   bash <skill-dir>/scripts/outside-voice.sh <target1>,<target2> "<instruction>" <artifact-path>
   bash <skill-dir>/scripts/outside-voice.sh --yes <target1>,<target2> "<instruction>" <artifact-path>
   ```

   If the artifact is gitignored, pass it as an exact file path — this is the
   case the tool fix exists for. A directory pathspec deliberately cannot reach
   ignored files.

   An explicitly named target whose CLI is absent warns and is dropped; if none
   are installed the tool exits 69. Propose from what is installed.

2. **Relay verbatim.** Reproduce each reviewer's framed output unedited and
   unsummarized, before any interpretation. This is what lets the user check
   the validation against what was actually said.

3. **Validate.** A separately labelled pass, and the load-bearing step —
   reviewing is cheap, believing is expensive. **Reproduce every finding before
   accepting it.** Evidence is a quote from the artifact, a command and its
   output, or a `file:line` reference. Verdict per finding: valid / partly
   valid / invalid / unverifiable.

   Measured failure modes to check for specifically, at a 60-70%
   useful-finding rate:
   - a severity label contradicted by the reviewer's own body text
   - a finding the current artifact already fixes
   - a remedy that would invert a correct assertion
   - confident conflation of two similar commands or concepts
   - a claim about the codebase that no file actually supports

4. **Verdict table.** `# | finding | verdict | evidence | proposed action`.

5. **Checkpoint.** Stop. The user adjudicates. **Fold nothing before this.**
   This is the rule the skill exists to enforce.

6. **Fold.** Apply only approved items, then re-run the inline self-review over
   the edited artifact. One gate per artifact — no automatic second round, since
   re-reviewing after every fold does not terminate. The user may re-run the
   gate by hand.

7. **Accept.** Show what actually changed and get acceptance of the final text.
   Approving a verdict table approves proposed actions, not the applied result;
   without this the artifact's last edit is unreviewed.

Gate states: `dispatched -> relayed -> validated -> adjudicated -> folded ->
self-reviewed -> accepted`.

Dropped and deferred findings are recorded in chat only, with the reason. If a
validated-invalid finding matters enough to survive the session, record it in
the artifact instead.
