"""remote_hello_task.py — task definition executed on the live Flyte cluster.

This is a plain Python file (the cluster runs Python action containers);
the Mojo SDK drives it as the control plane.
"""
import flyte

env = flyte.TaskEnvironment(name="mojo_remote")


@flyte.trace
def double(x: int) -> int:
    return x * 2


@env.task
def hello(name: str) -> str:
    return f"hello, {name}! doubled(21)={double(21)}"
