"""flyte — Flyte 2 SDK for Mojo.

Write a task as a plain Mojo function, bind it at compile time, and run it.
Where it runs is a property of the *config*, not of the code:

    from flyte import *

    def _hello(name: String) -> String:
        return "hello, " + name + "!"

    comptime env = TaskEnvironment["demo"]()
    comptime hello = env.task[f=_hello, name="hello"]()

    def main() raises:
        var cfg = init_from_config()                     # cluster config?
        var r = run[f=hello, name="demo.hello"]("flyte2")  # then run there
        print(r.output)

``mojo run hello.mojo`` executes in-process when there is no cluster
endpoint, and compiles + ships this same file to the cluster when there
is. See ``_mode`` for the three roles a program plays.
"""
from ._config import Config, MODE_LOCAL, MODE_REMOTE, MODE_WORKER, init_from_config, mode
from ._ctx import Ctx, ctx
from ._core import run, task, trace
from ._env import TaskEnvironment
from ._group import Group, group
from ._map import map
from ._mode import is_worker
from ._remote import remote_run
from ._run import Run
from ._spec import Cache, Resources
from ._wire import from_wire, to_wire
