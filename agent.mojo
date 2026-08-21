"""Agent — task + trace composition in Mojo (agent.mojo).

    def _summarize(q: String) -> String:
        return "summary(" + q + ")"

    def _double(x: Int) -> Int:
        return x * 2

    comptime env = TaskEnvironment["agent"]()
    comptime summarize = env.task[f=_summarize, name="summarize"]()
    comptime double = env.trace[f=_double, name="double"]()

    var run = run[f=summarize, name="agent.summarize"]("hello")
    print(run.report())

Run:
    mojo run agent.mojo
"""
from flyte import *


def _double(x: Int) -> Int:
    return x * 2


def _summarize(q: String) raises -> String:
    # a task may call bound traces (child actions) — recorded as a nested event
    var d = double(21)
    return "summary(" + q + ") doubled=" + String(d)


comptime env = TaskEnvironment["agent"]()
comptime double = env.trace[f=_double, name="double"]()
comptime summarize = env.task[f=_summarize, name="summarize"]()

def main() raises:
    var run = run[f=summarize, name="agent.summarize"]("hello")
    print(run.name)
    print(run.url)
    print(run.output)
    print()
    print(run.report())
