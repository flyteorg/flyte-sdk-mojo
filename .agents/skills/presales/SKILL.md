---
name: presales
description: >
  Union presales engineering lives in the `presales/` submodule
  (`unionai/presales`): discovery briefs, demo plans, and working Flyte
  prototypes per prospect (panorama, qbench, subquadratic and new ones).
  Use this skill whenever the user mentions a prospect or company and wants
  discovery context, a demo for an upcoming call, a POC / prototype / proof
  of an integration, or hands-on evidence for a specific use case — even if
  they don't say "presales" by name. The executable procedures are skills
  inside the submodule; read the matching SKILL.md in full before doing the
  work, and run discovery first when no brief exists.
---

# Presales — `presales/` submodule

`presales/` is a git submodule of `unionai/presales`: a presales workspace
where each prospect gets a discovery brief and, when the deal needs it, a
working Flyte prototype under `prospects/<company>/`. The procedures are
skills in `presales/.claude/skills/` — complete, self-contained runbooks.
**Read the matching SKILL.md in full before doing the work**, then follow it;
don't improvise around them.

## Routing

| Task | Read this first |
|---|---|
| What do we know about `<company>`? / extract requirements from a call | `presales/.claude/skills/discovery/SKILL.md` |
| Plan the demo for `<company>` (narrative, presentation-level) | `presales/.claude/skills/demo/SKILL.md` |
| Build a POC proving `<integration>` for `<company>` | `presales/.claude/skills/prototype/SKILL.md` |
| subquadratic SFT training experiment (change code → launch → evals follow) | `presales/prospects/subquadratic/debugging/generic-training/.claude/skills/sft-experiment/SKILL.md` |

## Workflow and judgment (from `presales/CLAUDE.md` — read it for the rest)

- **Discovery feeds everything.** Demo and prototype skills auto-invoke
  discovery when no brief exists. A brief already lives at
  `prospects/<company>/brief.md` where present (qbench has one).
- **Demo vs prototype** — demo when it's the first technical meeting or
  "how does it work?"; prototype when they said "show it working with [X]",
  are migrating (Airflow/KFP), are mid-evaluation on a tight timeline, or the
  champion is a coding ML engineer. Full table + five prospect archetypes
  (Airflow Migrator, MLOps Platform Builder, LLMOps Team, Data+ML Unifier,
  Kubeflow Escapee) and the Flyte plugin quick-reference (Airflow, MLflow,
  W&B, Ray, Databricks, Snowflake, SageMaker, Spark, dbt, Pandera, GE, Feast,
  KFP, Papermill) are in `presales/CLAUDE.md`.
- Positioning to preserve: Union is enterprise platform on Flyte — managed
  infra in *the customer's* cloud, real-time inference (ActorCore), SSO/RBAC.
  Key line: "the only AI runtime that runs in your cloud, not ours."

## MCP dependencies (check before assuming)

The skills reference Claude Code MCP tools. Before running a phase that
needs one, check it exists in the current harness and ask the user for
whatever is missing rather than faking a fetch:

| Tool | Used for |
|---|---|
| Flyte MCP (SSE, `FLYTE_MCP_API_KEY`) | the Union demo tenant — configured in `presales/.claude/settings.json` |
| Fathom | meeting transcripts → discovery |
| Google Drive/Docs/Sheets | briefs, deck content |
| Notion | prospect tracking, project pages |
| Slack / Linear / GitHub | coordination, prototype repos |

## Submodule mechanics

- New checkout: `git submodule update --init presales` (or `--init --recursive`).
- Prototype code and briefs are commits to `unionai/presales`, not this repo:
  branch, commit, and push **inside `presales/`**, then update the pin here
  only when the pointer should move.
- Prototypes are real Flyte projects (their own `.flyte` configs and
  `pyproject.toml`s, e.g. `prospects/qbench/`); treat their `RUNBOOK.md` /
  `README.md` as ground truth for how to run them.
