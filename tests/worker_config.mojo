"""Fixture: an environment with resources, and a task that overrides them.

    FLYTE_MOJO_ACTION=c.root FLYTE_MOJO_PROTOCOL=1 mojo run -I . tests/worker_config.mojo
"""
from flyte import *


def _heavy(x: Int) raises -> Int:
    return x * 2


def _light(x: Int) raises -> Int:
    return x + 1


def _root(x: Int) raises -> Int:
    return heavy(x) + light(x)


comptime env = TaskEnvironment["c", resources=Resources(cpu="1", memory="1Gi")]()
comptime heavy = env.task[f=_heavy, name="heavy", resources_override=Resources(cpu="4")]()
comptime light = env.task[f=_light, name="light"]()
comptime root = env.task[f=_root, name="root"]()


def main() raises:
    var r = env.run[f=root, name="c.root"](3)
    print("out:", r.output)
