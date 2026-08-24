"""Fib — native-speed compute, and the failure path.

The point of running Mojo on a cluster is that the task body is compiled
code, not an interpreter. ``fib`` is the smallest thing that shows it, and
``FIB_N=200 mojo run fib.mojo`` shows what a Mojo error looks like coming
back from the cluster.

    mojo run fib.mojo
    FIB_N=200 mojo run fib.mojo    # expect three attempts, then a non-zero exit
"""
from std.os import getenv

from flyte import *


def _fib(n: Int) raises -> Int:
    if n < 0 or n > 91:
        raise Error("n out of range (0..91): " + String(n))
    var a: Int = 0
    var b: Int = 1
    for _ in range(n):
        var t = a + b
        a = b
        b = t
    return a


# Two retries, so `make fib-fail` shows the cluster genuinely trying again:
# three attempts, then the original Mojo error.
comptime env = TaskEnvironment["demo", reliability=Reliability(retries=2, timeout=120)]()
comptime fib = env.task[f=_fib, name="fib"]()


def main() raises:
    var cfg = init_from_config()
    print("mode:", cfg.mode)

    # A bad FIB_N raises inside the task; remotely that surfaces as a failed
    # action whose message is the original Mojo error.
    var n = Int(getenv("FIB_N", "90"))
    var r = env.run[f=fib, name="demo.fib"](n)
    print("fib(" + String(n) + ") =", r.output)
    print("url:", r.url)
