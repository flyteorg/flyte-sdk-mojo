"""TaskEnvironment and Resources.

The environment name is a *compile-time* value (it is baked into the
qualified task names at bind time). Resources are descriptive metadata
for v1: they are recorded on the environment and surfaced in reports,
and will drive container resource requests when the environment is used
for remote runs.
"""
from ._core import _task0, _task1, _task2, _task3, _trace0, _trace1, _trace2, _trace3


struct Resources(ImplicitlyCopyable, Writable):
    var cpu: String
    var memory: String
    var gpu: Int
    var gpu_type: String

    def __init__(out self, *, cpu: String = "1", memory: String = "2Gi", gpu: Int = 0, gpu_type: String = ""):
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.gpu_type = gpu_type


struct TaskEnvironment[env_name: String](ImplicitlyCopyable, Writable):
    comptime name: String = Self.env_name
    var image: String
    var resources: Resources

    def __init__(out self, *, image: String = "ghcr.io/flyteorg/flyte:py3.13-v2.5.1", resources: Resources = Resources()):
        self.image = image
        self.resources = resources

    # -- task factories (fqn = "<env>.<name>") ----------------------------

    def task[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String](self) -> def() raises thin -> B:
        return _task0[f=f, fqn=self.name + "." + name]

    def task[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String](self) -> def(x: A) raises thin -> B:
        return _task1[f=f, fqn=self.name + "." + name]

    def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String](self) -> def(x: A, y: C) raises thin -> B:
        return _task2[f=f, fqn=self.name + "." + name]

    def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String](self) -> def(x: A, y: C, z: D) raises thin -> B:
        return _task3[f=f, fqn=self.name + "." + name]

    # -- trace factories ----------------------------------------------------

    def trace[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String](self) -> def() raises thin -> B:
        return _trace0[f=f, fqn=self.name + "." + name]

    def trace[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String](self) -> def(x: A) raises thin -> B:
        return _trace1[f=f, fqn=self.name + "." + name]

    def trace[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String](self) -> def(x: A, y: C) raises thin -> B:
        return _trace2[f=f, fqn=self.name + "." + name]

    def trace[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String](self) -> def(x: A, y: C, z: D) raises thin -> B:
        return _trace3[f=f, fqn=self.name + "." + name]
