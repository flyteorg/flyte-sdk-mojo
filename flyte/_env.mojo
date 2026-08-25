"""TaskEnvironment: the compile-time home for a task's name and configuration.

The environment name is baked into qualified task names at bind time, and so
is everything in ``_spec`` — resources and, as they land, the rest of Flyte's
per-task settings. All of it is a *compile-time parameter*, because binding
happens at compile time and a runtime field could not reach the binding:

    comptime env = TaskEnvironment["etl", resources=Resources(cpu="2")]()
    comptime score = env.task[
        f=_score, name="score", resources_override=Resources(cpu="8", gpu=1)
    ]()

``env.run`` is the counterpart to ``env.task``: a root action is launched
before its task body ever runs, so the free ``run[...]`` has no way to see
the task's configuration. Launch through the environment and it does.
"""
from ._core import (
    _run0, _run1, _run2, _run3,
    _task0, _task1, _task2, _task3,
    _trace0, _trace1, _trace2, _trace3,
)
from ._map import map as _map
from ._run import Run
from ._spec import Cache, Resources, encode_cache, encode_resources
from std.collections import List


struct TaskEnvironment[
    env_name: String,
    resources: Resources = Resources(),
    cache: Cache = Cache(),
](ImplicitlyCopyable, Movable):
    comptime name: String = Self.env_name
    comptime spec: String = encode_resources(Self.resources) + encode_cache(Self.cache)
    """This environment's configuration, encoded once at compile time."""

    def __init__(out self):
        pass

    # -- task factories (fqn = "<env>.<name>") ----------------------------

    def task[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String, resources_override: Resources = Resources(), cache_override: Cache = Cache()](self) -> def() raises thin -> B:
        return _task0[f=f, fqn=Self.name + "." + name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)]

    def task[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String, resources_override: Resources = Resources(), cache_override: Cache = Cache()](self) -> def(x: A) raises thin -> B:
        return _task1[f=f, fqn=Self.name + "." + name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)]

    def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String, resources_override: Resources = Resources(), cache_override: Cache = Cache()](self) -> def(x: A, y: C) raises thin -> B:
        return _task2[f=f, fqn=Self.name + "." + name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)]

    def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String, resources_override: Resources = Resources(), cache_override: Cache = Cache()](self) -> def(x: A, y: C, z: D) raises thin -> B:
        return _task3[f=f, fqn=Self.name + "." + name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)]

    # -- trace factories ----------------------------------------------------
    # A trace runs inside its caller's pod, so it has no configuration of
    # its own: it inherits whatever that action was given.

    def trace[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String](self) -> def() raises thin -> B:
        return _trace0[f=f, fqn=Self.name + "." + name]

    def trace[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String](self) -> def(x: A) raises thin -> B:
        return _trace1[f=f, fqn=Self.name + "." + name]

    def trace[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String](self) -> def(x: A, y: C) raises thin -> B:
        return _trace2[f=f, fqn=Self.name + "." + name]

    def trace[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String](self) -> def(x: A, y: C, z: D) raises thin -> B:
        return _trace3[f=f, fqn=Self.name + "." + name]

    # -- map: as the free map[...], but carrying this environment's config --
    #
    # A fan-out cannot read the configuration off the task it is given: `f` is
    # a bound function value and Mojo has no way to look at the parameters it
    # was built with. So the configuration for the children is declared here,
    # at the call site that launches them.

    def map[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String, resources_override: Resources = Resources(), cache_override: Cache = Cache()](self, items: List[A]) raises -> List[B]:
        return _map[f=f, name=name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)](items)

    # -- run: as the free run[...], but carrying this environment's config --

    def run[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String, run_name: String = "", resources_override: Resources = Resources(), cache_override: Cache = Cache()](self) raises -> Run[B]:
        return _run0[f=f, fqn=name, run_name=run_name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)]()

    def run[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String, run_name: String = "", resources_override: Resources = Resources(), cache_override: Cache = Cache()](self, x: A) raises -> Run[B]:
        return _run1[f=f, fqn=name, run_name=run_name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)](x)

    def run[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String, run_name: String = "", resources_override: Resources = Resources(), cache_override: Cache = Cache()](self, x: A, y: C) raises -> Run[B]:
        return _run2[f=f, fqn=name, run_name=run_name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)](x, y)

    def run[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String, run_name: String = "", resources_override: Resources = Resources(), cache_override: Cache = Cache()](self, x: A, y: C, z: D) raises -> Run[B]:
        return _run3[f=f, fqn=name, run_name=run_name, spec=Self.spec + encode_resources(resources_override) + encode_cache(cache_override)](x, y, z)
