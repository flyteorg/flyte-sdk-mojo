"""Hello — the minimal Flyte 2 task in Mojo (hello.mojo).

Run:
    mojo run hello.mojo
"""
from flyte import *


def _hello(name: String) -> String:
    return "hello, " + name + "!"


comptime env = TaskEnvironment["demo"]()
comptime hello = env.task[f=_hello, name="hello"]()

def main() raises:
    # direct call
    var msg = hello("flyte2")
    print(msg)

    # run as a Flyte run (local mode) and inspect the trace
    var run = run[f=hello, name="demo.hello"]("flyte2")
    print("run name:", run.name)
    print("run url:", run.url)
    print("run output:", run.output)
    print()
    print(run.report())
