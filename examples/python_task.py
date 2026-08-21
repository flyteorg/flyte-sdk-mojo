"""python_task.py — a plain Python Flyte task, driven from python_task.mojo.

Nothing Mojo-specific here: this is what an existing Flyte 2 Python task
looks like. ``remote_run`` in the Mojo driver launches it.
"""
import flyte

env = flyte.TaskEnvironment(name="mojo_remote")


@flyte.trace
def double(x: int) -> int:
    return x * 2


@env.task
def hello(name: str) -> str:
    return f"hello, {name}! doubled(21)={double(21)}"
