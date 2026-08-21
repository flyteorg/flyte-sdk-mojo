"""Failure-path test (live cluster) — a bad fib input must propagate as an error.

Runs a compiled-Mojo fib binary with invalid input on the cluster and
verifies the original Mojo panic message comes back through the SDK.

Run: mojo run remote_fail_test.mojo   (expect a non-zero exit)
"""
from std.collections import List

from flyte import *


def main() raises:
    init_from_config()
    var args: List[String] = ["abc"]
    var r = remote_run(file="mojo_tasks/hello_remote.py", task="fib", args=args)
    print("UNEXPECTED success:", r.output)
