"""Calling an existing *Python* task from Mojo — the escape hatch.

Most of this SDK is about running Mojo on the cluster. This is the other
direction: you already have a Python task and want a Mojo program to drive
it. ``remote_run`` names the file and the task; the Mojo side is purely the
control plane.

    mojo run python_task.mojo
"""
from std.collections import List

from flyte import *


def main() raises:
    var cfg = init_from_config()
    print("cluster:", cfg.endpoint, cfg.org, cfg.project, cfg.domain)

    var args: List[String] = ["flyte2"]
    var r = remote_run(file="python_task.py", task="hello", args=args)

    print("run:   ", r.name)
    print("url:   ", r.url)
    print("output:", r.output)
