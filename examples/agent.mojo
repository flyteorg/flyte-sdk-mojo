"""Agent — a data-dependent workflow, shaped like an agent loop.

The tool calls here are arithmetic stand-ins, not an LLM. The point is the
*shape*: the action tree is decided while the program runs, which is what
imperative workflows buy you.

    agent.solve                    root action
    ├─ agent.plan                  child
    │   └─ agent.tokenize          trace
    ├─ agent.search x N            children, fanned out in parallel
    ├─ agent.critique              child
    │   └─ agent.rerank            grandchild — a child of a child
    └─ agent.answer                child

``N`` comes from the question, and whether a second search round happens
depends on what ``critique`` says — neither is known until the run is under
way.

    mojo run agent.mojo
    QUESTION="how fast is mojo on flyte" mojo run agent.mojo
"""
from std.collections import List
from std.os import getenv

from flyte import *


# ---------------------------------------------------------------------------
# Traces — in-process spans
# ---------------------------------------------------------------------------


def _tokenize(question: String) -> Int:
    return len(question.split(" "))


# ---------------------------------------------------------------------------
# Tasks — each becomes its own Flyte action
# ---------------------------------------------------------------------------


def _plan(question: String) raises -> String:
    """Break the question into sub-questions — one per word, capped at 4."""
    var words = question.split(" ")
    var n = tokenize(question)
    var subs = List[String]()
    for i in range(min(n, 4)):
        subs.append(String(words[i]))
    if len(subs) == 0:
        raise Error("cannot plan for an empty question")
    return String("|").join(subs)


def _search(sub: String) raises -> Int:
    """Score one sub-question. CPU-bound so the work is really in Mojo."""
    var h: Int = sub.byte_length() * 2654435761
    for _ in range(5_000_000):
        h = (h * 1103515245 + 12345) & 0x3FFFFFFF
    return h & 0xFFFF


def _rerank(total: Int) raises -> Int:
    """A child of critique — proves nesting goes deeper than one level."""
    return (total * 31) & 0xFFFF


def _critique(total: Int) raises -> String:
    var r = rerank(total)
    return "sufficient" if r > 20000 else "insufficient"


def _answer(question: String, verdict: String) raises -> String:
    return "answer(" + question + ") [" + verdict + "]"


def _solve(question: String) raises -> String:
    var plan_out = plan(question)                       # child action

    var subs = List[String]()
    for part in plan_out.split("|"):
        subs.append(String(part))

    var scores = map[f=search, name="agent.search"](subs)   # parallel children
    var total: Int = 0
    for s in scores:
        total += s

    var verdict = critique(total)                       # child (has its own child)

    # data-dependent: a weak first pass buys one more round
    if verdict == "insufficient":
        var again = map[f=search, name="agent.search"](subs)
        for s in again:
            total += s
        verdict = critique(total)

    return answer(question, verdict)                    # child action


comptime env = TaskEnvironment["agent"]()

comptime tokenize = env.trace[f=_tokenize, name="tokenize"]()

comptime plan = env.task[f=_plan, name="plan"]()
comptime search = env.task[f=_search, name="search"]()
comptime rerank = env.task[f=_rerank, name="rerank"]()
comptime critique = env.task[f=_critique, name="critique"]()
comptime answer = env.task[f=_answer, name="answer"]()
comptime solve = env.task[f=_solve, name="solve"]()


def main() raises:
    var cfg = init_from_config()
    print("mode:", cfg.mode)

    var question = String(getenv("QUESTION", "what is mojo"))
    var r = run[f=solve, name="agent.solve"](question)
    print("run:   ", r.name)
    print("url:   ", r.url)
    print("output:", r.output)
    print()
    print(r.report())
