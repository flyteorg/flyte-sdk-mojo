"""Pipeline — a multi-action workflow written as one Mojo file.

Run it and the Flyte UI shows a real action tree, not one opaque box:

    etl.pipeline                  root action
    ├─ etl.extract                child action (its own pod)
    │   └─ etl.normalize          trace — an in-process span
    └─ scoring                    a group, named by the code below
        ├─ etl.score  x4          child actions, in parallel, on 2 CPUs each
        └─ etl.summarize          child action
            └─ etl.grade          trace

The rule is the one Flyte already uses: **a bound task called from inside a
task becomes a child action; a bound trace stays in-process and is recorded
as a span.** `with group(...)` names a region of the workflow. Nothing here
is remote-specific — locally the same file runs in one process and prints
the same tree as a report.

    mojo run pipeline.mojo
"""
from std.collections import List

from flyte import *


# ---------------------------------------------------------------------------
# Traces — in-process, but visible in the UI with real timings
# ---------------------------------------------------------------------------


def _normalize(rows: Int) -> String:
    """Turn a row count into the id list the rest of the pipeline works on."""
    var ids = List[String]()
    for i in range(rows):
        ids.append(String(i * 7 + 1))
    return String(",").join(ids)


def _grade(total: Int) -> String:
    if total > 3_000_000_000:
        return "hot"
    elif total > 1_000_000_000:
        return "warm"
    return "cold"


# ---------------------------------------------------------------------------
# Tasks — each one becomes its own Flyte action
# ---------------------------------------------------------------------------


def _extract(rows: Int) raises -> String:
    """Produce the work items. Cheap; the trace inside it is the point."""
    if rows <= 0:
        raise Error("rows must be positive, got " + String(rows))
    return normalize(rows)


def _score(item: Int) raises -> Int:
    """CPU-bound scoring — the reason to run Mojo rather than Python.

    A 20M-round mixing loop: microseconds of native code per round, and the
    whole thing is a rounding error next to pod startup.
    """
    var h: Int = item * 2654435761
    for _ in range(20_000_000):
        h = (h * 1103515245 + 12345) & 0x3FFFFFFF
    return h


def _summarize(total: Int, count: Int) raises -> String:
    return (
        "scored "
        + String(count)
        + " items, total="
        + String(total)
        + ", grade="
        + grade(total)
    )


def _pipeline(rows: Int) raises -> String:
    """The workflow. Every call below is an action or a span in the UI."""
    var csv = extract(rows)                       # child action

    var items = List[Int]()
    for part in csv.split(","):
        items.append(Int(String(part)))

    # everything launched in here lands under "scoring" in the UI
    with group("scoring"):
        # 2 CPUs each, declared where the children are launched
        var scores = env.map[
            f=score, name="etl.score", resources_override=Resources(cpu="2", memory="2Gi")
        ](items)

        var total: Int = 0
        for s in scores:
            total += s

        return summarize(total, len(scores))      # child action


# The orchestrator is idle most of its life; the scoring actions are not.
comptime env = TaskEnvironment["etl", resources=Resources(cpu="1", memory="1Gi")]()

comptime normalize = env.trace[f=_normalize, name="normalize"]()
comptime grade = env.trace[f=_grade, name="grade"]()

comptime extract = env.task[f=_extract, name="extract"]()
comptime score = env.task[f=_score, name="score"]()
comptime summarize = env.task[f=_summarize, name="summarize"]()
comptime pipeline = env.task[f=_pipeline, name="pipeline"]()


def main() raises:
    var cfg = init_from_config()
    print("mode:", cfg.mode)

    # env.run, not run: a root action is launched before its body runs, so
    # only the environment can say how it should be configured.
    var r = env.run[f=pipeline, name="etl.pipeline"](4)
    print("run:   ", r.name)
    print("url:   ", r.url)
    print("output:", r.output)
    print()
    print(r.report())
