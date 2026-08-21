"""flyte — Flyte 2 SDK for Mojo.

Base local SDK: define tasks and traces as plain Mojo functions, bind them
at compile time, and run them in-process with a readable trace. Live
cluster runs are driven through the Python ``flyte`` control plane.

    from flyte import *

    def _summarize(q: String) -> String: ...

    comptime env = TaskEnvironment["demo"]()
    comptime summarize = env.task[f=_summarize, name="summarize"]()
    var run = run[f=summarize, name="summarize"]("hello")
    print(run.name, run.url, run.output)
    print(run.report())
"""
from ._config import Config, init_from_config
from ._ctx import Ctx, ctx
from ._core import run, task, trace
from ._env import Resources, TaskEnvironment
from ._remote import remote_run
from ._run import Run
