"""Fixture program for the worker-role checks in `make test-worker`.

Two tasks in a row, so a worker launched for the *second* one has to replay
its way past the first. ``step`` announces itself, which is how the test
tells "replayed and re-executed" apart from "read out of the journal".

    FLYTE_MOJO_ACTION=j.final mojo run tests/worker_flow.mojo
"""
from flyte import *


def _step(x: Int) raises -> Int:
    print("EXECUTED step(" + String(x) + ")")
    return x * 10


def _label(x: Int) -> String:
    return "n" + String(x)


def _final(x: Int) raises -> String:
    var out: String = ""
    with group("finishing"):
        out = "final:" + label(x)
    return out


def _flow(x: Int) raises -> String:
    var a = step(x)
    return final(a)


comptime env = TaskEnvironment["j"]()
comptime label = env.trace[f=_label, name="label"]()
comptime step = env.task[f=_step, name="step"]()
comptime final = env.task[f=_final, name="final"]()
comptime flow = env.task[f=_flow, name="flow"]()


def main() raises:
    var r = run[f=flow, name="j.flow"](2)
    print("out:", r.output)
