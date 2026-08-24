"""Fixture: the control plane must refuse to run from inside an action.

An action steering the run it belongs to is a deadlock waiting to happen, so
these calls raise in a worker rather than quietly doing nothing.

    FLYTE_MOJO_ACTION=cp.probe mojo run -I . tests/worker_control.mojo
"""
from flyte import *


def _probe(x: Int) raises -> String:
    var refused = 0
    try:
        _ = runs(limit=1)
    except e:
        refused += 1
    try:
        _ = status("whatever")
    except e:
        refused += 1
    try:
        _ = abort("whatever")
    except e:
        refused += 1
    try:
        _ = logs("whatever")
    except e:
        refused += 1
    try:
        _ = rerun("whatever")
    except e:
        refused += 1
    return "refused=" + String(refused)


comptime env = TaskEnvironment["cp"]()
comptime probe = env.task[f=_probe, name="probe"]()


def main() raises:
    var r = run[f=probe, name="cp.probe"](1)
    print("out:", r.output)
