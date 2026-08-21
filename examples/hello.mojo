"""Hello — the minimal Flyte task in Mojo.

One file. Where it runs is a property of the config, not of this code:

    mojo run hello.mojo

    no ~/.flyte/config.yaml   the task runs in-process
    a cluster config          this file is compiled for linux/amd64 and the
                              task runs natively inside a Flyte action

Force in-process execution against a cluster config with
``init_from_config(mode="local")``.
"""
from flyte import *


def _hello(name: String) -> String:
    return "hello, " + name + "!"


comptime env = TaskEnvironment["demo"]()
comptime hello = env.task[f=_hello, name="hello"]()


def main() raises:
    var cfg = init_from_config()
    print("mode:", cfg.mode, "  cluster:", cfg.endpoint)

    var r = run[f=hello, name="demo.hello"]("flyte2")
    print("run:   ", r.name)
    print("url:   ", r.url)
    print("output:", r.output)
